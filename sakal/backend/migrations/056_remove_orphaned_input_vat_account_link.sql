-- ============================================================
-- Migration 056: Remove the orphaned INPUT_VAT_ACCOUNT link type
-- ============================================================
-- Found during a completeness audit of the Purchase Bill module: 054
-- seeded a new 'INPUT_VAT_ACCOUNT' rim_account_link_types row, but
-- fn_approve_purchase_invoice never resolves it via fn_resolve_account_link
-- — it reads rim_taxes.gl_input_account_id directly (the tax's own
-- configured Input GL account), same as every other tax-account lookup in
-- this codebase. So the link type was dead on arrival: Account Link Setup
-- would happily let an admin configure a default for it, and that value
-- would be silently ignored by every function that posts Input VAT.
--
-- Removing it outright rather than leaving it "for a future redesign" —
-- if per-tax-group VAT account overrides via the generic link mechanism
-- are ever wanted, re-seed it then and wire fn_approve_purchase_invoice to
-- actually call fn_resolve_account_link for it.
--
-- Defensive cleanup order: delete any dependent rim_account_link_setup /
-- rim_account_link_defaults rows first (a company may have visited Account
-- Link Setup and configured a default for it since 054 shipped), then the
-- type itself.
-- ============================================================

DELETE FROM rim_account_link_defaults
WHERE link_type_id IN (SELECT id FROM rim_account_link_types WHERE link_key = 'INPUT_VAT_ACCOUNT');

DELETE FROM rim_account_link_setup
WHERE link_type_id IN (SELECT id FROM rim_account_link_types WHERE link_key = 'INPUT_VAT_ACCOUNT');

DELETE FROM rim_account_link_types WHERE link_key = 'INPUT_VAT_ACCOUNT';
