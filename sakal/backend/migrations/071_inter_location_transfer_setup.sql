-- ============================================================
-- Migration 071: Inter-Location Stock Transfer — setup
-- ============================================================
-- Groundwork for the three documents that follow (072/073/074): Stock
-- Transfer Request (intent, mirrors Material Requisition but location ->
-- location instead of location -> department), Stock Transfer (dispatch,
-- mirrors GRN's DIRECT/AGAINST_PO duality via an against-request flag,
-- gains freight/transportation charges the same way PO/GRN already have
-- them), and Stock Receipt (arrival, confirms actual received qty which
-- can be less than transferred — transit shortage).
--
-- Design discussed and confirmed live:
--
-- 1. ric_location_groups gains inter_entity_sales_account_id/
--    inter_entity_cogs_account_id — DIRECT columns, resolved by a plain
--    lookup (location -> group -> column), NOT through the generic
--    fn_resolve_account_link framework. That framework resolves by
--    PRODUCT granularity (COMPANY/CATEGORY/LOCATION/ITEM) — the wrong fit
--    here, since inter-entity Sales/COGS need ONE account per GROUP,
--    configured once, never varying by product (they're elimination
--    entries at consolidation — splitting them by category would make
--    elimination harder, not easier). Forcing this through the generic
--    framework via LOCATION granularity would require configuring the
--    same account on every location in a group individually, an easy
--    thing to forget when a group gains a new location later.
--
-- 2. Two independent postings for INTER_ENTITY cross-group transfers,
--    both final at Transfer-approve time (no revenue reversal later):
--      STXS — Dr TO_group.customer_account_id / Cr FROM_group's
--             inter_entity_sales_account_id, at sales_price x qty.
--      STXC — Dr FROM_group's inter_entity_cogs_account_id / Cr Stock
--             (per product), at cost_price x qty.
--    sales_price - cost_price is this group's recognized profit on the
--    internal transfer. Matches "FOB shipping point" commercial practice
--    (very standard for inter-company transfers) — FROM's revenue
--    recognition does not depend on what TO eventually confirms receiving.
--
-- 3. Same-book transfers (SIMPLE model, or INTER_ENTITY same group_id)
--    use a NEW STOCK_IN_TRANSIT_ACCOUNT-based STXJ journal instead —
--    that link type was seeded in 032 and never used until now, same
--    "unused-stub-until-the-right-module" story as STOCK_CONSUMPTION_
--    ACCOUNT (removed, 066) and MIC's own STOCK_ACCOUNT reuse.
--
-- 4. A NEW STOCK_TRANSFER_LOSS_ACCOUNT link type (product-based, via the
--    generic framework — genuinely product-dependent, unlike #1) absorbs
--    the value gap whenever Stock Receipt confirms less than what was
--    transferred, for BOTH same-book and inter-entity cases:
--      Dr Stock@TO (received qty's value) + Dr Transfer Loss (shortfall's
--      value) = Cr [Stock-in-Transit | FROM_group.supplier_account_id]
--                (full ORIGINALLY TRANSFERRED value) — always balances.
--    For inter-entity, TO's payable (Cr FROM_group.supplier_account_id)
--    is fixed at the FULL transferred qty x sales_price regardless of
--    shortage — mirrors "bill for what was shipped" — so a shortage is
--    TO's own write-off, not a dispute that unwinds FROM's already-final
--    STXS/STXC.
--
-- 5. Charges (freight): captured on the Stock Transfer document, same
--    apportion-by-value mechanism as PO/GRN (rim_additional_charges,
--    now widened to allow applicable_on='TRANSFER'). Their GL timing
--    differs by mode:
--      Same-book: posted immediately in the Transfer's own STXJ (Dr
--        Stock-in-Transit includes charges; each charge's own account Cr's
--        once, full amount, exactly like GRN's charge posting).
--      Inter-entity: DEFERRED to Receipt's STXP (Dr Stock@TO includes
--        charges; each charge's own account Cr's once, full amount) —
--        charges are a landed-cost concern for the BUYING entity, which
--        only "owns" that concern once the purchase is actually recorded.
--
-- 6. Cost-price availability is checked at Transfer-approve (never at
--    Receipt — Receipt just uses whatever the Transfer already resolved):
--    a hard block if FROM location's rim_product_location.cost_price is
--    zero/unset for any line's product.
--
-- 7. Negative-stock / batch-serial: no new logic needed anywhere in this
--    setup migration — Transfer's outward movement calls the EXISTING
--    fn_post_stock_movement exactly like every other module, so the
--    established item-AND-location flag check (untracked) and the
--    always-blocked strict check (batch/serial) apply automatically.
--    ril_stock_ledger's trans_type CHECK constraints already include
--    TRANSFER_OUT/TRANSFER_IN since the original 036 migration — no
--    constraint change needed this time (unlike MATERIAL_ISSUE, which
--    needed 069/070).
--
-- 8. If either location's group_id is NULL, treat the transfer as
--    same-book automatically (never a hard error) — you cannot do
--    inter-entity billing without both groups configured, and defaulting
--    to the simpler path is safer than blocking a company still mid-setup.
-- ============================================================


-- ── 1. ric_location_groups: inter-entity Sales/COGS accounts ────────────────
ALTER TABLE ric_location_groups
    ADD COLUMN IF NOT EXISTS inter_entity_sales_account_id UUID REFERENCES rim_accounts(id),
    ADD COLUMN IF NOT EXISTS inter_entity_cogs_account_id  UUID REFERENCES rim_accounts(id);


-- ── 2. New product-based account link type: transfer shortage write-off ────
INSERT INTO rim_account_link_types (link_key, link_name, sort_order) VALUES
    ('STOCK_TRANSFER_LOSS_ACCOUNT', 'Stock Transfer Loss Account', 140)
ON CONFLICT (link_key) DO NOTHING;


-- ── 3. Widen rim_additional_charges.applicable_on for TRANSFER ──────────────
ALTER TABLE rim_additional_charges DROP CONSTRAINT IF EXISTS rim_additional_charges_applicable_on_check;
ALTER TABLE rim_additional_charges ADD CONSTRAINT rim_additional_charges_applicable_on_check
    CHECK (applicable_on IN ('SALES','PURCHASE','BOTH','TRANSFER'));


-- ── 4. Voucher types: numbering (STRQ/STXF/SRCP) + GL posting (STXJ/STXS/STXC/STXP) ──
INSERT INTO rim_voucher_types (
    voucher_type_code, type_description, voucher_nature,
    cash_bank_side, reset_frequency, trans_no_format, is_system
) VALUES
    ('STRQ', 'Stock Transfer Request',              'STOCK', NULL, 'YEARLY', 'STRQ/{LOC}/{YYYY}/{SEQ5}', true),
    ('STXF', 'Stock Transfer',                        'STOCK', NULL, 'YEARLY', 'STXF/{LOC}/{YYYY}/{SEQ5}', true),
    ('SRCP', 'Stock Receipt',                          'STOCK', NULL, 'YEARLY', 'SRCP/{LOC}/{YYYY}/{SEQ5}', true),
    ('STXJ', 'Stock Transfer Journal (same book)',       'STOCK', NULL, 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true),
    ('STXS', 'Inter-Entity Transfer Sale',                'STOCK', NULL, 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true),
    ('STXC', 'Inter-Entity Transfer Cost of Sale',         'STOCK', NULL, 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true),
    ('STXP', 'Inter-Entity Transfer Purchase',              'STOCK', NULL, 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true)
ON CONFLICT DO NOTHING;


-- ── 5. Menu seeding for existing companies ───────────────────────────────────
-- IN-TRF ('Stock Transfer', /inventory/transfers) already exists as a
-- placeholder from initial scaffolding — its screen gets replaced with the
-- real one in Flutter, no menu row change needed. Only the Request and
-- Receipt screens are new menu entries.
INSERT INTO ric_master_menus (
    client_id, company_id, module_id, feature_code, feature_name, screen_name,
    serial_no, group_code, group_name, group_serial_no,
    approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT co.client_id, co.id, sm.id, v.feature_code, v.feature_name, v.screen_name,
       v.serial_no, v.group_code, v.group_name, v.group_serial_no,
       v.approve_allowed, false, false
FROM ric_companies co
JOIN ric_system_modules sm ON sm.client_id = co.client_id AND sm.company_id = co.id AND sm.module_code = 'IN'
CROSS JOIN (VALUES
    ('IN-STR', 'Stock Transfer Request', '/inventory/stock-transfer-requests', 5, 'IN-OPS', 'Operations', 0, true),
    ('IN-SRC', 'Stock Receipt',          '/inventory/stock-receipts',           6, 'IN-OPS', 'Operations', 0, true)
) AS v(feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed)
ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
    SET group_code      = excluded.group_code,
        group_name      = excluded.group_name,
        group_serial_no = excluded.group_serial_no;
