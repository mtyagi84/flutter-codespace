-- ═══════════════════════════════════════════════════════════════════════════
-- Migration 197 — Remove 3 orphaned "Coming Soon" menu items
-- ═══════════════════════════════════════════════════════════════════════════
-- User spotted a live "Stock List" sidebar item routing to a
-- `_Placeholder('Stock List')` widget ("Coming soon") and asked how many
-- other orphaned placeholder menu items exist. Grepped app_router.dart for
-- every remaining use of the shared `_Placeholder` widget (7 routes), then
-- cross-checked each against ric_master_menus across all 7 live companies:
--
--   /purchase/payments        PR-PAY  Supplier Payment      -- LIVE, all 7 companies, is_active=true
--   /inventory/stock          IN-STK  Stock List             -- LIVE, all 7 companies, is_active=true
--   /finance/cashbook         FN-CBK  Cash Book              -- LIVE, all 7 companies, is_active=true
--   /setup/financial-years            Financial Years        -- no menu row anywhere, dead route only
--   /finance/trial-balance            (was FN-TRB)           -- already repointed to /reports/TRIAL_BALANCE by migration 135; this route is dead code only
--   /finance/profit-loss              (was FN-PNL)           -- already repointed to /reports/PROFIT_LOSS_SUMMARY; dead code only
--   /finance/balance-sheet            (was FN-BSH)           -- already repointed to /reports/BALANCE_SHEET_SUMMARY; dead code only
--
-- Only the first three ever showed as a real, clickable "Coming soon" menu
-- item — the other four had zero menu rows pointing to them in any
-- company (either never seeded, or already migrated to a real reporting-
-- engine route by migration 135) and were purely dead Flutter route
-- declarations, cleaned up directly in app_router.dart/route_names.dart
-- (along with the now-fully-unused `_Placeholder` widget class) in the
-- same commit as this migration.
--
-- This migration hides the three LIVE orphaned items via the existing
-- is_active/is_deleted mechanism (ric_master_menus's own documented
-- convention: "a feature blocked at master level never shows even if the
-- user has view_allowed=true" — no ric_user_menus change needed). Also
-- removed from backend/functions/fn_seed_client_modules.sql in the same
-- commit so future companies never get them seeded — that function needs
-- a manual CREATE OR REPLACE re-run in the Supabase SQL editor (this
-- project's own established deployment convention for this file; it is
-- not applied automatically by numbered migrations).
-- ═══════════════════════════════════════════════════════════════════════════

UPDATE ric_master_menus
SET is_active = false, is_deleted = true, updated_at = now()
WHERE feature_code IN ('PR-PAY', 'IN-STK', 'FN-CBK')
  AND is_deleted = false;
