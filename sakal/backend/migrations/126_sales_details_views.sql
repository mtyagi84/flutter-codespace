-- ============================================================
-- Migration 126: v_sales_details_base / v_sales_details_local
-- Shared base views for every future Sales report (Sales Register,
-- item-wise summary, customer-wise summary, salesperson performance,
-- etc.) — built once here, reused by every future report's own
-- ric_report_definitions row rather than re-derived per report.
-- ============================================================
-- Design, per user specification (2026-08-05 session):
--
-- 1. Joins Sales Invoice header+lines UNION ALL Sales Return header+lines
--    — one row per LINE, from either document type.
-- 2. Outer-joined against customer/product/location/UOM/salesperson/
--    currency/tax-group for human-readable names, not just IDs.
-- 3. Every monetary column is pre-converted — v_sales_details_base uses
--    each document's own rate_to_base, v_sales_details_local uses
--    rate_to_local (both already stored per-header — the schema's
--    existing "always-multiply, rate stored per document" convention,
--    same as every other multi-currency posting in this app). qty
--    columns are NEVER rate-multiplied (a quantity doesn't have a
--    currency) — only rate/gross/discount/tax/charge/landed/final
--    amount columns are.
-- 4. record_type = 'S' (Sales Invoice line) or 'R' (Sales Return line).
-- 5. Every Return row's qty + amount columns are NEGATED (unit `rate`
--    is the one deliberate exception — a per-unit price stays positive,
--    matching standard ERP convention; only the extended/cumulative
--    columns flip sign) — so SUM(...) over both record_types nets to
--    actual net sales with zero special-case logic needed downstream.
-- 6. TWO invoice-identity columns, deliberately different:
--      doc_no/doc_date    — THIS row's own document (invoice_no/date
--                            for an S row, return_no/date for an R row)
--      invoice_no/invoice_date — the ORIGINAL Sales Invoice this line
--                            traces back to. For an S row this is
--                            trivially itself. For an R row, this is
--                            rih_sales_return_headers.invoice_no/
--                            invoice_date — a column that ALREADY
--                            stores the original invoice reference
--                            (NOT the return's own return_no/date).
--                            GROUP BY invoice_no, invoice_date therefore
--                            nets a Sales Invoice against every Return
--                            raised against it, regardless of which
--                            document each row actually came from.
--
-- Header-level MONETARY AGGREGATE columns (rih_sales_invoices.
-- gross_amount/discount_amount/tax_amount/charges_amount/grand_total,
-- rih_sales_return_headers.taxable_amount/tax_amount/charges_amount/
-- return_total) are DELIBERATELY EXCLUDED — user's own call, made after
-- reviewing a first draft: since these are themselves computed by
-- summing the line-level amounts at save time, exposing BOTH creates a
-- real risk (a report author sums the header column across multiple
-- joined line rows and silently overcounts by however many lines exist
-- on that document) with no upside (item-wise SUM already gives the
-- same number, and is the single source of truth if the two ever
-- drifted apart from a bug). Any report that needs a document-level
-- total should SUM(final_amount) GROUP BY doc_no, doc_date instead.
-- Two header-only monetary fields with NO line-level equivalent
-- (rih_sales_invoices.collected_amount_local/base, cash actually
-- collected; rih_sales_return_headers.refund_amount_local/base, cash
-- actually refunded) are also excluded — those describe a CASH
-- MOVEMENT, a different reporting concern (collections/receipts) than
-- this view's scope (the sale/return itself). Add a dedicated
-- collections view later if that's ever needed; don't retrofit it here.
--
-- Status is NOT filtered in the view (user's own choice, both options
-- offered) — every DRAFT/APPROVED/CANCELLED row is included, with
-- `status` exposed as a column. Every future report built on this view
-- MUST filter status='APPROVED' itself (via ric_report_filters, a
-- DROPDOWN_STATIC default) unless it deliberately wants to show
-- drafts/cancellations — this is a real, easy-to-forget footgun, flagged
-- here so it isn't rediscovered as a bug once the first report ships.
--
-- RLS: both views run with INVOKER rights (Postgres default for views)
-- over already-RLS-protected base tables (auth_rw_sales_invoices,
-- auth_rw_si_lines, auth_rw_sales_return_headers, auth_rw_sr_lines) —
-- client_id/company_id scoping is inherited for free, same as every
-- other view in this schema. GRANT mirrors v_pending_bills' own
-- precedent (020_pending_bills_view.sql) — RLS denies by default for
-- any role with no matching policy, so granting SELECT to anon does not
-- bypass tenant scoping.
-- ============================================================

-- DROP + CREATE, not CREATE OR REPLACE: Postgres refuses to REPLACE a
-- view when a column's data type changes (42P16 "cannot change data type
-- of view column"), which this view will keep tripping while its column
-- set is still being reviewed/iterated on with the user. Nothing else in
-- the schema references these views yet (brand new, no dependents), so
-- DROP is safe.
DROP VIEW IF EXISTS v_sales_details_base;
CREATE VIEW v_sales_details_base AS
-- ---------------------------------------------------------------
-- Sales Invoice lines (record_type = 'S')
-- ---------------------------------------------------------------
SELECT
    'S'::text                              AS record_type,
    h.client_id,
    h.company_id,
    h.location_id,
    loc.location_name,
    loc.location_short,
    h.invoice_no                           AS doc_no,
    h.invoice_date                         AS doc_date,
    h.invoice_no                           AS invoice_no,
    h.invoice_date                         AS invoice_date,
    l.serial_no                            AS line_serial_no,
    NULL::integer                          AS invoice_line_serial,
    h.status,
    h.customer_id,
    cust.account_code                      AS customer_code,
    cust.account_name                      AS customer_name,
    h.party_name,
    h.party_phone,
    h.party_address,
    h.sales_person_id,
    sp.full_name                           AS sales_person_name,
    l.product_id,
    prod.product_code,
    prod.product_name,
    l.item_description,
    l.barcode,
    l.uom_id,
    uom.description                        AS uom_name,
    l.uom_conversion_factor,
    l.tax_group_id,
    tg.group_code                          AS tax_group_code,
    tg.group_name                          AS tax_group_name,
    h.invoice_currency_id                  AS currency_id,     -- FK to rim_currencies.id, not the ISO code
    cur.currency_id                        AS currency_code,   -- rim_currencies' own ISO-code column
    h.rate_to_base,
    h.rate_to_local,
    l.qty_pack,
    l.qty_loose,
    l.base_qty,
    (l.rate * h.rate_to_base)              AS rate,
    l.discount_percent,
    (l.discount_amount * h.rate_to_base)   AS discount_amount,
    l.discount_given_by,
    (l.gross_amount * h.rate_to_base)      AS gross_amount,
    (l.tax_amount * h.rate_to_base)        AS tax_amount,
    (l.charge_amount * h.rate_to_base)     AS charge_amount,
    (l.landed_amount * h.rate_to_base)     AS landed_amount,
    l.base_amount                          AS final_amount,    -- reuse the stored, actually-posted value — never recompute
    -- coalesce(...,0): cost_price is nullable (pre-121 historical invoices
    -- never had it resolved) — NULL * anything = NULL in Postgres, exactly
    -- like Oracle's NVL gap, so an un-coalesced cost_value would silently
    -- vanish from any downstream SUM() instead of reading as a visible 0.
    (coalesce(l.cost_price, 0) * h.rate_to_base) AS cost_price,
    (l.base_qty * coalesce(l.cost_price, 0) * h.rate_to_base) AS cost_value,
    l.price_source,
    l.price_override_reason,
    l.price_source_entry_no,
    l.source_quotation_line_serial,
    l.source_order_line_serial,
    h.invoice_mode,
    h.quotation_no,
    h.quotation_date,
    h.order_no,
    h.order_date,
    h.sale_type,
    h.stock_dispatch_mode,
    h.cash_collection_mode,
    h.sales_voucher_no,
    h.sales_voucher_date,
    h.cos_voucher_no,
    h.cos_voucher_date,
    NULL::text                             AS credit_note_voucher_no,
    NULL::date                             AS credit_note_voucher_date,
    NULL::text                             AS reason,
    h.cancellation_reason,
    h.remarks                              AS doc_remarks,
    l.remarks                              AS line_remarks,
    h.approved_by,
    h.approved_at,
    h.created_at                           AS doc_created_at,
    h.created_by                           AS doc_created_by,
    h.updated_at                           AS doc_updated_at,
    h.updated_by                           AS doc_updated_by,
    l.created_at                           AS line_created_at,
    l.created_by                           AS line_created_by,
    l.updated_at                           AS line_updated_at,
    l.updated_by                           AS line_updated_by
FROM rih_sales_invoices h
JOIN rid_sales_invoice_lines l
    ON  l.client_id = h.client_id AND l.company_id = h.company_id
    AND l.invoice_no = h.invoice_no AND l.invoice_date = h.invoice_date
LEFT JOIN rim_accounts        cust ON cust.id = h.customer_id
LEFT JOIN rim_products        prod ON prod.id = l.product_id
LEFT JOIN rim_common_masters  uom  ON uom.id  = l.uom_id
LEFT JOIN ric_locations       loc  ON loc.id  = h.location_id
LEFT JOIN rim_users           sp   ON sp.id   = h.sales_person_id
LEFT JOIN rim_currencies      cur  ON cur.id  = h.invoice_currency_id
LEFT JOIN rim_tax_groups      tg   ON tg.id   = l.tax_group_id
WHERE h.is_deleted = false AND l.is_deleted = false

UNION ALL

-- ---------------------------------------------------------------
-- Sales Return lines (record_type = 'R') — qty/amounts negated
-- ---------------------------------------------------------------
SELECT
    'R'::text                              AS record_type,
    rh.client_id,
    rh.company_id,
    rh.location_id,
    loc.location_name,
    loc.location_short,
    rh.return_no                           AS doc_no,
    rh.return_date                         AS doc_date,
    rh.invoice_no                          AS invoice_no,      -- ORIGINAL invoice reference, not this row's own doc
    rh.invoice_date                        AS invoice_date,
    rl.serial_no                           AS line_serial_no,
    rl.invoice_line_serial,
    rh.status,
    rh.customer_id,
    cust.account_code                      AS customer_code,
    cust.account_name                      AS customer_name,
    NULL::text                             AS party_name,
    NULL::text                             AS party_phone,
    NULL::text                             AS party_address,
    NULL::uuid                             AS sales_person_id,
    NULL::text                             AS sales_person_name,
    rl.product_id,
    prod.product_code,
    prod.product_name,
    NULL::text                             AS item_description,
    rl.barcode,
    rl.uom_id,
    uom.description                        AS uom_name,
    rl.uom_conversion_factor,
    rl.tax_group_id,
    tg.group_code                          AS tax_group_code,
    tg.group_name                          AS tax_group_name,
    rh.return_currency_id                  AS currency_id,
    cur.currency_id                        AS currency_code,
    rh.rate_to_base,
    rh.rate_to_local,
    (-1 * rl.qty_pack)                     AS qty_pack,
    (-1 * rl.qty_loose)                    AS qty_loose,
    (-1 * rl.base_qty)                     AS base_qty,
    (rl.rate * rh.rate_to_base)            AS rate,            -- unit rate stays positive, same as every S row
    -- rid_sales_return_lines has no discount_amount column at all — but the
    -- discount WAS taken back: gross/tax/final are each independently
    -- prorated from the invoice line's own gross/tax/final (see
    -- sales_return_entry_screen.dart's fraction/grossAmount/taxAmount/
    -- finalAmount getters), and the invoice line satisfies
    -- final = gross - discount + tax (sales_invoice_entry_screen.dart:1242-
    -- 1245) — an identity preserved under proportional scaling. So the
    -- discount amount is recoverable as gross + tax - final; there's simply
    -- no column to read it FROM directly, unlike every other amount here.
    (CASE WHEN rl.gross_amount <> 0
          THEN (rl.gross_amount + rl.tax_amount - rl.final_amount) / rl.gross_amount * 100
          ELSE 0 END)::numeric(6,2)        AS discount_percent,
    (-1 * (rl.gross_amount + rl.tax_amount - rl.final_amount) * rh.rate_to_base) AS discount_amount,
    NULL::uuid                             AS discount_given_by,
    (-1 * rl.gross_amount  * rh.rate_to_base) AS gross_amount,
    (-1 * rl.tax_amount    * rh.rate_to_base) AS tax_amount,
    (-1 * rl.charge_amount * rh.rate_to_base) AS charge_amount,
    (-1 * rl.landed_amount * rh.rate_to_base) AS landed_amount,
    (-1 * rl.final_amount  * rh.rate_to_base) AS final_amount, -- no stored base_amount on return lines — must compute
    -- rh.rate_to_base IS the original invoice's own rate_to_base — copied
    -- verbatim onto the return header at fn_save_sales_return time
    -- (099_sales_return.sql line ~399) and never re-derived, so this is
    -- already historically symmetric with what fn_approve_sales_return
    -- actually reverses, no separate join back to rih_sales_invoices needed.
    (coalesce(rl.cost_price, 0) * rh.rate_to_base) AS cost_price,
    (-1 * rl.base_qty * coalesce(rl.cost_price, 0) * rh.rate_to_base) AS cost_value,
    NULL::text                             AS price_source,
    NULL::text                             AS price_override_reason,
    NULL::text                             AS price_source_entry_no,
    NULL::integer                          AS source_quotation_line_serial,
    NULL::integer                          AS source_order_line_serial,
    NULL::text                             AS invoice_mode,
    NULL::text                             AS quotation_no,
    NULL::date                             AS quotation_date,
    NULL::text                             AS order_no,
    NULL::date                             AS order_date,
    NULL::text                             AS sale_type,
    NULL::text                             AS stock_dispatch_mode,
    NULL::text                             AS cash_collection_mode,
    NULL::text                             AS sales_voucher_no,
    NULL::date                             AS sales_voucher_date,
    rh.cos_voucher_no,
    rh.cos_voucher_date,
    rh.credit_note_voucher_no,
    rh.credit_note_voucher_date,
    rh.reason,
    NULL::text                             AS cancellation_reason,
    rh.remarks                             AS doc_remarks,
    NULL::text                             AS line_remarks,
    rh.approved_by,
    rh.approved_at,
    rh.created_at                          AS doc_created_at,
    rh.created_by                          AS doc_created_by,
    rh.updated_at                          AS doc_updated_at,
    rh.updated_by                          AS doc_updated_by,
    rl.created_at                          AS line_created_at,
    rl.created_by                          AS line_created_by,
    rl.updated_at                          AS line_updated_at,
    rl.updated_by                          AS line_updated_by
FROM rih_sales_return_headers rh
JOIN rid_sales_return_lines rl
    ON  rl.client_id = rh.client_id AND rl.company_id = rh.company_id
    AND rl.return_no = rh.return_no AND rl.return_date = rh.return_date
LEFT JOIN rim_accounts        cust ON cust.id = rh.customer_id
LEFT JOIN rim_products        prod ON prod.id = rl.product_id
LEFT JOIN rim_common_masters  uom  ON uom.id  = rl.uom_id
LEFT JOIN ric_locations       loc  ON loc.id  = rh.location_id
LEFT JOIN rim_currencies      cur  ON cur.id  = rh.return_currency_id
LEFT JOIN rim_tax_groups      tg   ON tg.id   = rl.tax_group_id
WHERE rh.is_deleted = false AND rl.is_deleted = false;

GRANT SELECT ON v_sales_details_base TO anon, authenticated, service_role;


-- ============================================================
-- v_sales_details_local — identical shape, converted via each
-- document's own rate_to_local instead of rate_to_base, and reusing
-- rid_sales_invoice_lines.local_amount (not base_amount) for an S row's
-- final_amount.
-- ============================================================
DROP VIEW IF EXISTS v_sales_details_local;
CREATE VIEW v_sales_details_local AS
SELECT
    'S'::text                              AS record_type,
    h.client_id,
    h.company_id,
    h.location_id,
    loc.location_name,
    loc.location_short,
    h.invoice_no                           AS doc_no,
    h.invoice_date                         AS doc_date,
    h.invoice_no                           AS invoice_no,
    h.invoice_date                         AS invoice_date,
    l.serial_no                            AS line_serial_no,
    NULL::integer                          AS invoice_line_serial,
    h.status,
    h.customer_id,
    cust.account_code                      AS customer_code,
    cust.account_name                      AS customer_name,
    h.party_name,
    h.party_phone,
    h.party_address,
    h.sales_person_id,
    sp.full_name                           AS sales_person_name,
    l.product_id,
    prod.product_code,
    prod.product_name,
    l.item_description,
    l.barcode,
    l.uom_id,
    uom.description                        AS uom_name,
    l.uom_conversion_factor,
    l.tax_group_id,
    tg.group_code                          AS tax_group_code,
    tg.group_name                          AS tax_group_name,
    h.invoice_currency_id                  AS currency_id,
    cur.currency_id                        AS currency_code,
    h.rate_to_base,
    h.rate_to_local,
    l.qty_pack,
    l.qty_loose,
    l.base_qty,
    (l.rate * h.rate_to_local)             AS rate,
    l.discount_percent,
    (l.discount_amount * h.rate_to_local)  AS discount_amount,
    l.discount_given_by,
    (l.gross_amount * h.rate_to_local)     AS gross_amount,
    (l.tax_amount * h.rate_to_local)       AS tax_amount,
    (l.charge_amount * h.rate_to_local)    AS charge_amount,
    (l.landed_amount * h.rate_to_local)    AS landed_amount,
    l.local_amount                         AS final_amount,    -- reuse the stored, actually-posted value — never recompute
    (coalesce(l.cost_price, 0) * h.rate_to_local) AS cost_price,
    (l.base_qty * coalesce(l.cost_price, 0) * h.rate_to_local) AS cost_value,
    l.price_source,
    l.price_override_reason,
    l.price_source_entry_no,
    l.source_quotation_line_serial,
    l.source_order_line_serial,
    h.invoice_mode,
    h.quotation_no,
    h.quotation_date,
    h.order_no,
    h.order_date,
    h.sale_type,
    h.stock_dispatch_mode,
    h.cash_collection_mode,
    h.sales_voucher_no,
    h.sales_voucher_date,
    h.cos_voucher_no,
    h.cos_voucher_date,
    NULL::text                             AS credit_note_voucher_no,
    NULL::date                             AS credit_note_voucher_date,
    NULL::text                             AS reason,
    h.cancellation_reason,
    h.remarks                              AS doc_remarks,
    l.remarks                              AS line_remarks,
    h.approved_by,
    h.approved_at,
    h.created_at                           AS doc_created_at,
    h.created_by                           AS doc_created_by,
    h.updated_at                           AS doc_updated_at,
    h.updated_by                           AS doc_updated_by,
    l.created_at                           AS line_created_at,
    l.created_by                           AS line_created_by,
    l.updated_at                           AS line_updated_at,
    l.updated_by                           AS line_updated_by
FROM rih_sales_invoices h
JOIN rid_sales_invoice_lines l
    ON  l.client_id = h.client_id AND l.company_id = h.company_id
    AND l.invoice_no = h.invoice_no AND l.invoice_date = h.invoice_date
LEFT JOIN rim_accounts        cust ON cust.id = h.customer_id
LEFT JOIN rim_products        prod ON prod.id = l.product_id
LEFT JOIN rim_common_masters  uom  ON uom.id  = l.uom_id
LEFT JOIN ric_locations       loc  ON loc.id  = h.location_id
LEFT JOIN rim_users           sp   ON sp.id   = h.sales_person_id
LEFT JOIN rim_currencies      cur  ON cur.id  = h.invoice_currency_id
LEFT JOIN rim_tax_groups      tg   ON tg.id   = l.tax_group_id
WHERE h.is_deleted = false AND l.is_deleted = false

UNION ALL

SELECT
    'R'::text                              AS record_type,
    rh.client_id,
    rh.company_id,
    rh.location_id,
    loc.location_name,
    loc.location_short,
    rh.return_no                           AS doc_no,
    rh.return_date                         AS doc_date,
    rh.invoice_no                          AS invoice_no,
    rh.invoice_date                        AS invoice_date,
    rl.serial_no                           AS line_serial_no,
    rl.invoice_line_serial,
    rh.status,
    rh.customer_id,
    cust.account_code                      AS customer_code,
    cust.account_name                      AS customer_name,
    NULL::text                             AS party_name,
    NULL::text                             AS party_phone,
    NULL::text                             AS party_address,
    NULL::uuid                             AS sales_person_id,
    NULL::text                             AS sales_person_name,
    rl.product_id,
    prod.product_code,
    prod.product_name,
    NULL::text                             AS item_description,
    rl.barcode,
    rl.uom_id,
    uom.description                        AS uom_name,
    rl.uom_conversion_factor,
    rl.tax_group_id,
    tg.group_code                          AS tax_group_code,
    tg.group_name                          AS tax_group_name,
    rh.return_currency_id                  AS currency_id,
    cur.currency_id                        AS currency_code,
    rh.rate_to_base,
    rh.rate_to_local,
    (-1 * rl.qty_pack)                     AS qty_pack,
    (-1 * rl.qty_loose)                    AS qty_loose,
    (-1 * rl.base_qty)                     AS base_qty,
    (rl.rate * rh.rate_to_local)           AS rate,
    (CASE WHEN rl.gross_amount <> 0
          THEN (rl.gross_amount + rl.tax_amount - rl.final_amount) / rl.gross_amount * 100
          ELSE 0 END)::numeric(6,2)        AS discount_percent,
    (-1 * (rl.gross_amount + rl.tax_amount - rl.final_amount) * rh.rate_to_local) AS discount_amount,
    NULL::uuid                             AS discount_given_by,
    (-1 * rl.gross_amount  * rh.rate_to_local) AS gross_amount,
    (-1 * rl.tax_amount    * rh.rate_to_local) AS tax_amount,
    (-1 * rl.charge_amount * rh.rate_to_local) AS charge_amount,
    (-1 * rl.landed_amount * rh.rate_to_local) AS landed_amount,
    (-1 * rl.final_amount  * rh.rate_to_local) AS final_amount,
    (coalesce(rl.cost_price, 0) * rh.rate_to_local) AS cost_price,
    (-1 * rl.base_qty * coalesce(rl.cost_price, 0) * rh.rate_to_local) AS cost_value,
    NULL::text                             AS price_source,
    NULL::text                             AS price_override_reason,
    NULL::text                             AS price_source_entry_no,
    NULL::integer                          AS source_quotation_line_serial,
    NULL::integer                          AS source_order_line_serial,
    NULL::text                             AS invoice_mode,
    NULL::text                             AS quotation_no,
    NULL::date                             AS quotation_date,
    NULL::text                             AS order_no,
    NULL::date                             AS order_date,
    NULL::text                             AS sale_type,
    NULL::text                             AS stock_dispatch_mode,
    NULL::text                             AS cash_collection_mode,
    NULL::text                             AS sales_voucher_no,
    NULL::date                             AS sales_voucher_date,
    rh.cos_voucher_no,
    rh.cos_voucher_date,
    rh.credit_note_voucher_no,
    rh.credit_note_voucher_date,
    rh.reason,
    NULL::text                             AS cancellation_reason,
    rh.remarks                             AS doc_remarks,
    NULL::text                             AS line_remarks,
    rh.approved_by,
    rh.approved_at,
    rh.created_at                          AS doc_created_at,
    rh.created_by                          AS doc_created_by,
    rh.updated_at                          AS doc_updated_at,
    rh.updated_by                          AS doc_updated_by,
    rl.created_at                          AS line_created_at,
    rl.created_by                          AS line_created_by,
    rl.updated_at                          AS line_updated_at,
    rl.updated_by                          AS line_updated_by
FROM rih_sales_return_headers rh
JOIN rid_sales_return_lines rl
    ON  rl.client_id = rh.client_id AND rl.company_id = rh.company_id
    AND rl.return_no = rh.return_no AND rl.return_date = rh.return_date
LEFT JOIN rim_accounts        cust ON cust.id = rh.customer_id
LEFT JOIN rim_products        prod ON prod.id = rl.product_id
LEFT JOIN rim_common_masters  uom  ON uom.id  = rl.uom_id
LEFT JOIN ric_locations       loc  ON loc.id  = rh.location_id
LEFT JOIN rim_currencies      cur  ON cur.id  = rh.return_currency_id
LEFT JOIN rim_tax_groups      tg   ON tg.id   = rl.tax_group_id
WHERE rh.is_deleted = false AND rl.is_deleted = false;

GRANT SELECT ON v_sales_details_local TO anon, authenticated, service_role;
