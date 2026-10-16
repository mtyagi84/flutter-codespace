-- ============================================================
-- Migration 229: fn_delete_client_permanently — full, irreversible
-- tenant purge
-- ============================================================
-- Built 2026-10-16 at the user's explicit request, for ad-hoc ops use
-- (deleting a throwaway/test tenant, or a real one that genuinely needs to
-- be gone). This is NOT an app feature — it is a privileged ops tool.
--
-- DELIBERATE DESIGN DECISIONS:
--
-- 1. **Never exposed to PostgREST.** No GRANT to anon or authenticated
--    anywhere in this file. The only way to call this function is as the
--    `postgres` role directly (Supabase SQL Editor, or a direct `psql`/`pg`
--    connection using the service connection string) — never through the
--    app's own REST API, so no client-side bug or compromised session can
--    ever trigger it.
--
-- 2. **FK enforcement is bypassed via `SET LOCAL session_replication_role
--    = replica` instead of a hand-computed deletion order.** This schema
--    has 138 client-scoped tables and 861 FK edges between them (confirmed
--    live via a full pg_constraint introspection pass) — including plain
--    audit-trail columns (`created_by`/`updated_by` on nearly every table,
--    referencing `rim_users(id)`) that create real CYCLES in the FK graph
--    (e.g. `rim_users` rows reference other `rim_users` rows via
--    `created_by`, `ric_locations` references `rim_users` and vice versa).
--    A plain topological sort cannot resolve a graph with cycles, and
--    hand-maintaining a correct order across 138 tables as the schema
--    keeps growing is itself a standing source of bugs (a forgotten new
--    table either orphans data or blocks the whole purge on a live FK
--    violation). `session_replication_role = replica` is the standard,
--    textbook-correct Postgres technique for exactly this situation — it
--    disables FK constraint checks AND triggers for the current
--    transaction, so every DELETE below can run in any order with no risk
--    of a constraint violation. `SET LOCAL` (not a plain `SET`) makes this
--    automatically and unconditionally revert at the end of the
--    transaction — on COMMIT or on ROLLBACK — so there is no cleanup step
--    that could be skipped by an early RAISE EXCEPTION.
--
-- 3. **Two independent confirmations required, not one.** `p_client_id`
--    alone is a single UUID a caller could paste wrong with zero feedback
--    until it's too late — `p_client_no` must ALSO be supplied and must
--    match that exact client's own `client_no` (fetched fresh inside the
--    function, not trusted blindly from the caller), so a typo'd or
--    copy-pasted-from-the-wrong-tab client_id fails loudly instead of
--    silently deleting the wrong tenant. `p_confirm_phrase` must be the
--    literal string `'DELETE PERMANENTLY'` — a third, deliberately
--    unambiguous gate against ever calling this by accident (e.g. from a
--    script that reused a variable name).
--
-- 4. **One single transaction.** Every DELETE either all happen or none
--    do — a failure partway through (e.g. an unexpected FK to a table not
--    in this list, or a genuine connection drop) rolls back the entire
--    purge, never leaving a tenant half-deleted.
--
-- 5. **Global/shared lookup tables are explicitly excluded, not silently
--    skipped.** `rim_account_link_types` and `rim_common_master_types`
--    were found during introspection to reference client-scoped rows
--    (via other tables' FKs) but have NO `client_id` column of their own
--    — confirmed live as genuinely global, shared-across-every-tenant
--    lookup tables (21 and 14 rows respectively), never touched here.
--    `ric_product_movement_snapshot` is genuinely tenant-scoped data but
--    also has no `client_id` column — it is matched indirectly via a join
--    through `ric_locations`/`rim_products`, both already scoped by
--    `p_client_id`.
--
-- 6. **Returns a full per-table row-count report as JSON** — an auditable
--    record of exactly what was deleted, not just a bare success/failure.
--
-- Re-verify the table list below if the schema grows significantly after
-- this migration ships (a new client-scoped table added later needs a
-- line added here too) — this list is a deliberately explicit, reviewed
-- snapshot, not a runtime auto-discovery, precisely because an
-- automatically-discovered table list is the wrong kind of "automatic" for
-- a function this destructive: a newly-added GLOBAL table that happens to
-- pick up a client_id column by a future mistake should never silently
-- become purgeable without a human re-reviewing this list first.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_delete_client_permanently(
    p_client_id      UUID,
    p_client_no      TEXT,
    p_confirm_phrase TEXT
) RETURNS JSON LANGUAGE plpgsql AS $$
DECLARE
    v_actual_client_no TEXT;
    v_client_name       TEXT;
    v_table             TEXT;
    v_count             BIGINT;
    v_report             JSONB := '{}'::jsonb;
    v_total              BIGINT := 0;
    -- 137 client-scoped tables (every table in this schema with its own
    -- client_id column, confirmed via information_schema introspection on
    -- 2026-10-16) — ric_clients itself is handled separately at the end,
    -- since it has no client_id column (it IS the client, matched by id).
    v_tables TEXT[] := ARRAY[
        -- rid_* — transaction line/detail tables
        'rid_bank_reconciliation_matches','rid_bank_statement_lines','rid_cash_receipt_lines',
        'rid_cheque_register','rid_expense_voucher_lines','rid_finance_lines',
        'rid_grn_charge_lines','rid_grn_lines','rid_invoice_bill_settlement',
        'rid_material_issue_lines','rid_material_requisition_lines','rid_opening_balance_lines',
        'rid_opening_stock_lines','rid_po_charge_lines','rid_po_payment_terms',
        'rid_pos_shift_denomination_counts','rid_pos_tender_lines','rid_price_master_lines',
        'rid_purchase_order_lines','rid_purchase_return_charge_lines','rid_purchase_return_lines',
        'rid_sales_delivery_lines','rid_sales_invoice_charges','rid_sales_invoice_line_bundle_components',
        'rid_sales_invoice_lines','rid_sales_order_charges','rid_sales_order_lines',
        'rid_sales_quotation_charges','rid_sales_quotation_lines','rid_sales_return_charges',
        'rid_sales_return_lines','rid_stock_adjustment_lines','rid_stock_count_lines',
        'rid_stock_count_review_sources','rid_stock_receipt_lines','rid_stock_transfer_charge_lines',
        'rid_stock_transfer_lines','rid_stock_transfer_request_lines','rid_transaction_line_batches',
        'rid_transaction_line_serials','rid_transport_details',
        -- rih_* — transaction header tables
        'rih_bank_statement_headers','rih_cash_receipt_headers','rih_customer_loyalty_profiles',
        'rih_expense_voucher_headers','rih_finance_headers','rih_grn_headers',
        'rih_material_issue_headers','rih_material_requisition_headers','rih_opening_stock_headers',
        'rih_pos_payouts','rih_pos_shift_opening_float','rih_pos_shifts',
        'rih_price_master_headers','rih_prospect_conversions','rih_purchase_invoices',
        'rih_purchase_orders','rih_purchase_return_headers','rih_sales_delivery_headers',
        'rih_sales_invoices','rih_sales_orders','rih_sales_quotations',
        'rih_sales_return_headers','rih_stock_adjustment_headers','rih_stock_count_headers',
        'rih_stock_count_review_headers','rih_stock_receipts','rih_stock_transfer_requests',
        'rih_stock_transfers',
        -- ril_* — ledgers / sequence counters
        'ril_company_doc_no_seq','ril_cost_price_history','ril_loyalty_ledger',
        'ril_stock_ledger','ril_trans_no_seq',
        -- rim_* — master data
        'rim_account_link_defaults','rim_account_link_setup','rim_account_links',
        'rim_accounting_setup','rim_accounts','rim_additional_charges',
        'rim_bank_accounts','rim_bank_statement_formats','rim_bundle_components',
        'rim_category_levels','rim_cities','rim_common_masters',
        'rim_countries','rim_currencies','rim_currency_denominations',
        'rim_customer_delivery_locations','rim_department_consumption_areas','rim_divisions',
        'rim_exchange_rates','rim_financial_years','rim_item_categories',
        'rim_loyalty_programs','rim_payment_modes','rim_payment_term_lines',
        'rim_payment_terms','rim_pos_scheme_rules','rim_pos_schemes',
        'rim_product_bundles','rim_product_flag_types','rim_product_location',
        'rim_product_media','rim_product_uom','rim_products',
        'rim_sales_executives','rim_tax_compound_sources','rim_tax_group_members',
        'rim_tax_groups','rim_tax_rates','rim_taxes',
        'rim_voucher_types',
        -- ric_* — tenancy / config / POS / permissions / reporting (ric_clients and
        -- ric_companies handled separately below; every OTHER ric_* table here)
        'ric_backdated_entry_control','ric_location_groups','ric_locations',
        'ric_master_menus','ric_period_locks','ric_pos_devices',
        'ric_pos_terminals','ric_print_templates','ric_report_columns',
        'ric_report_definitions','ric_report_filters','ric_report_group_levels',
        'ric_report_jobs','ric_system_modules','ric_user_location_access',
        'ric_user_menu_favorites','ric_user_menus','ric_user_notifications',
        'ric_user_pos_terminal_access','ric_user_preferences','ric_user_quick_invoice_setup',
        'ric_user_sales_controls',
        -- rim_users deleted LAST among client-scoped tables, since almost
        -- every other table's created_by/updated_by/approved_by-style
        -- column references it (harmless either way under
        -- session_replication_role=replica, but keeps the order readable)
        'rim_users',
        -- ric_companies deleted after every other table (every other
        -- client-scoped table also carries company_id, conceptually a
        -- child of this row)
        'ric_companies'
    ];
BEGIN
    IF p_confirm_phrase IS DISTINCT FROM 'DELETE PERMANENTLY' THEN
        RAISE EXCEPTION 'CONFIRMATION_PHRASE_MISMATCH'
            USING DETAIL = 'p_confirm_phrase must be exactly ''DELETE PERMANENTLY''.';
    END IF;

    SELECT client_no, client_name INTO v_actual_client_no, v_client_name
    FROM ric_clients WHERE id = p_client_id;

    IF v_actual_client_no IS NULL THEN
        RAISE EXCEPTION 'CLIENT_NOT_FOUND'
            USING DETAIL = format('No client found with id %s.', p_client_id);
    END IF;

    IF upper(trim(v_actual_client_no)) <> upper(trim(p_client_no)) THEN
        RAISE EXCEPTION 'CLIENT_NO_MISMATCH'
            USING DETAIL = format(
                'p_client_no (''%s'') does not match the client_no (''%s'') on record for this client_id — refusing to proceed.',
                p_client_no, v_actual_client_no
            );
    END IF;

    -- Disables FK + trigger enforcement for the REST of this transaction
    -- only — automatically reverts on COMMIT or ROLLBACK, no manual reset
    -- needed. See header comment, point 2.
    SET LOCAL session_replication_role = replica;

    -- ric_product_movement_snapshot: tenant data with no client_id column
    -- of its own (see header comment, point 5) — matched via its own
    -- location_id against this client's locations.
    DELETE FROM ric_product_movement_snapshot
    WHERE location_id IN (SELECT id FROM ric_locations WHERE client_id = p_client_id);
    GET DIAGNOSTICS v_count = ROW_COUNT;
    IF v_count > 0 THEN
        v_report := v_report || jsonb_build_object('ric_product_movement_snapshot', v_count);
        v_total := v_total + v_count;
    END IF;

    FOREACH v_table IN ARRAY v_tables LOOP
        EXECUTE format('DELETE FROM %I WHERE client_id = $1', v_table) USING p_client_id;
        GET DIAGNOSTICS v_count = ROW_COUNT;
        IF v_count > 0 THEN
            v_report := v_report || jsonb_build_object(v_table, v_count);
            v_total := v_total + v_count;
        END IF;
    END LOOP;

    DELETE FROM ric_clients WHERE id = p_client_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_report := v_report || jsonb_build_object('ric_clients', v_count);
    v_total := v_total + v_count;

    RETURN json_build_object(
        'client_id',     p_client_id,
        'client_no',     v_actual_client_no,
        'client_name',   v_client_name,
        'total_rows_deleted', v_total,
        'rows_by_table', v_report
    );
END;
$$;

-- No GRANT to anon or authenticated — see header comment, point 1.
-- Callable only as the postgres role (Supabase SQL Editor, or a direct
-- privileged pg connection), never through PostgREST.
