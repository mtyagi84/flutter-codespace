-- ============================================================
-- 025_tax_master_test.sql — pgTAP tests for migration 025
--
-- Tables: rim_tax_types, rim_taxes, rim_tax_compound_sources,
--         rim_tax_rates, rim_tax_groups, rim_tax_group_members
-- Functions: fn_get_active_tax_rate, fn_replace_group_members
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run entire file.
--   3. All rows show "ok N — ..." with no "not ok" lines.
--   4. finish() returns no rows = all passed.
--
-- Hardcoded fixture UUIDs — no temp tables (Supabase auto-commits DO blocks).
-- ============================================================

BEGIN;

-- ── Fixtures ──────────────────────────────────────────────────────────────────
DO $$
DECLARE
  -- Tenant
  v_client_id  uuid := '00000000-0000-0000-0001-000000000001';
  v_company_id uuid := '00000000-0000-0000-0001-000000000002';
  v_user_id    uuid := '00000000-0000-0000-0001-000000000003';
  -- Taxes
  v_tax_vat    uuid := '00000000-0000-0005-0000-000000000001';  -- TVA 16%
  v_tax_wht    uuid := '00000000-0000-0005-0000-000000000002';  -- WHT_RENT 10%
  v_tax_cgst   uuid := '00000000-0000-0005-0000-000000000003';  -- CGST 18%
  v_tax_sgst   uuid := '00000000-0000-0005-0000-000000000004';  -- SGST 18%
  -- Rates
  v_rate_vat1  uuid := '00000000-0000-0006-0000-000000000001';  -- TVA STANDARD 16% from 2024-01-01
  v_rate_vat2  uuid := '00000000-0000-0006-0000-000000000002';  -- TVA STANDARD 18% from 2025-01-01
  v_rate_vat3  uuid := '00000000-0000-0006-0000-000000000003';  -- TVA ZERO 0%
  v_rate_wht1  uuid := '00000000-0000-0006-0000-000000000004';  -- WHT STANDARD 10%
  -- Groups
  v_grp_drc    uuid := '00000000-0000-0007-0000-000000000001';  -- DRC Standard
  v_grp_gst    uuid := '00000000-0000-0007-0000-000000000002';  -- India GST
  v_grp_tmp    uuid := '00000000-0000-0007-0000-000000000099';  -- temp for cascade test
  -- Members
  v_mem1       uuid := '00000000-0000-0008-0000-000000000001';
  v_mem2       uuid := '00000000-0000-0008-0000-000000000002';
  v_mem3       uuid := '00000000-0000-0008-0000-000000000003';
BEGIN
  -- Tenant
  INSERT INTO ric_clients  (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST CO', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_id, v_client_id, v_company_id, 'test', 'Test User', 'x', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  -- Taxes
  INSERT INTO rim_taxes (id, client_id, company_id, tax_code, tax_name, tax_type_code, applicable_on, created_by)
  VALUES (v_tax_vat, v_client_id, v_company_id, 'TVA', 'TVA DRC 16%', 'VAT', 'BOTH', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_taxes (id, client_id, company_id, tax_code, tax_name, tax_type_code, applicable_on, created_by)
  VALUES (v_tax_wht, v_client_id, v_company_id, 'WHT_RENT', 'WHT on Rent 10%', 'WITHHOLDING', 'PURCHASE', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_taxes (id, client_id, company_id, tax_code, tax_name, tax_type_code, applicable_on, created_by)
  VALUES (v_tax_cgst, v_client_id, v_company_id, 'CGST', 'CGST 18%', 'GST', 'BOTH', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_taxes (id, client_id, company_id, tax_code, tax_name, tax_type_code, applicable_on, created_by)
  VALUES (v_tax_sgst, v_client_id, v_company_id, 'SGST', 'SGST 18%', 'GST', 'BOTH', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  -- Rates: TVA at 16% from 2024-01-01, 18% from 2025-01-01
  INSERT INTO rim_tax_rates (id, client_id, company_id, tax_id, rate_label, rate, effective_from, created_by)
  VALUES (v_rate_vat1, v_client_id, v_company_id, v_tax_vat, 'STANDARD', 16.0000, '2024-01-01', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_tax_rates (id, client_id, company_id, tax_id, rate_label, rate, effective_from, created_by)
  VALUES (v_rate_vat2, v_client_id, v_company_id, v_tax_vat, 'STANDARD', 18.0000, '2025-01-01', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_tax_rates (id, client_id, company_id, tax_id, rate_label, rate, effective_from, created_by)
  VALUES (v_rate_vat3, v_client_id, v_company_id, v_tax_vat, 'ZERO', 0.0000, '2024-01-01', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_tax_rates (id, client_id, company_id, tax_id, rate_label, rate, effective_from, created_by)
  VALUES (v_rate_wht1, v_client_id, v_company_id, v_tax_wht, 'STANDARD', 10.0000, '2024-01-01', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  -- Groups
  INSERT INTO rim_tax_groups (id, client_id, company_id, group_code, group_name, applicable_on, created_by)
  VALUES (v_grp_drc, v_client_id, v_company_id, 'DRC_STANDARD', 'DRC Standard (TVA 16%)', 'BOTH', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_tax_groups (id, client_id, company_id, group_code, group_name, applicable_on, created_by)
  VALUES (v_grp_gst, v_client_id, v_company_id, 'IND_GST_18', 'India GST 18%', 'BOTH', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  -- Temp group for cascade test
  INSERT INTO rim_tax_groups (id, client_id, company_id, group_code, group_name, applicable_on, created_by)
  VALUES (v_grp_tmp, v_client_id, v_company_id, 'TMP_GROUP', 'Temp Group', 'BOTH', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  -- Members
  INSERT INTO rim_tax_group_members (id, client_id, company_id, tax_group_id, tax_id, sequence_no)
  VALUES (v_mem1, v_client_id, v_company_id, v_grp_drc, v_tax_vat, 1)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_tax_group_members (id, client_id, company_id, tax_group_id, tax_id, sequence_no)
  VALUES (v_mem2, v_client_id, v_company_id, v_grp_gst, v_tax_cgst, 1)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_tax_group_members (id, client_id, company_id, tax_group_id, tax_id, sequence_no)
  VALUES (v_mem3, v_client_id, v_company_id, v_grp_gst, v_tax_sgst, 2)
  ON CONFLICT (id) DO NOTHING;

  -- Temp group member (for cascade delete test)
  INSERT INTO rim_tax_group_members (id, client_id, company_id, tax_group_id, tax_id, sequence_no)
  VALUES (gen_random_uuid(), v_client_id, v_company_id, v_grp_tmp, v_tax_vat, 1)
  ON CONFLICT DO NOTHING;

  -- Now hard-delete the temp group to test ON DELETE CASCADE
  DELETE FROM rim_tax_groups WHERE id = v_grp_tmp;
END;
$$ LANGUAGE plpgsql;

-- ── Plan ──────────────────────────────────────────────────────────────────────
SELECT plan(22);

-- ══════════════════════════════════════════════════════════════════════════════
-- Section A: rim_tax_types (global seeds)
-- ══════════════════════════════════════════════════════════════════════════════

SELECT ok(
  EXISTS (SELECT 1 FROM rim_tax_types WHERE tax_type_code = 'VAT' AND is_withholding = false),
  'ok 1 — VAT type seeded with is_withholding = false'
);

SELECT ok(
  (SELECT is_withholding FROM rim_tax_types WHERE tax_type_code = 'WITHHOLDING') = true,
  'ok 2 — WITHHOLDING type has is_withholding = true'
);

SELECT ok(
  (SELECT COUNT(*)::int FROM rim_tax_types WHERE is_active = true) >= 7,
  'ok 3 — all 7 tax types seeded'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Section B: rim_taxes
-- ══════════════════════════════════════════════════════════════════════════════

SELECT ok(
  EXISTS (SELECT 1 FROM rim_taxes WHERE id = '00000000-0000-0005-0000-000000000001'),
  'ok 4 — TVA tax inserted'
);

SELECT ok(
  (SELECT tax_type_code FROM rim_taxes WHERE id = '00000000-0000-0005-0000-000000000002') = 'WITHHOLDING',
  'ok 5 — WHT_RENT has tax_type_code = WITHHOLDING'
);

SELECT ok(
  (SELECT is_reverse_charge FROM rim_taxes WHERE id = '00000000-0000-0005-0000-000000000001') = false,
  'ok 6 — is_reverse_charge defaults to false'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_name = 'rim_taxes' AND constraint_type = 'UNIQUE'
  ),
  'ok 7 — UNIQUE constraint exists on rim_taxes'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM information_schema.check_constraints cc
    JOIN   information_schema.constraint_column_usage cu ON cc.constraint_name = cu.constraint_name
    WHERE  cu.table_name = 'rim_taxes' AND cc.check_clause LIKE '%applicable_on%'
  ),
  'ok 8 — applicable_on CHECK constraint exists on rim_taxes'
);

-- Soft delete test
UPDATE rim_taxes SET is_deleted = true, updated_by = '00000000-0000-0000-0001-000000000003', updated_at = now()
WHERE id = '00000000-0000-0005-0000-000000000002';

SELECT ok(
  NOT EXISTS (SELECT 1 FROM rim_taxes WHERE id = '00000000-0000-0005-0000-000000000002' AND is_deleted = false),
  'ok 9 — soft delete: WHT_RENT excluded from is_deleted=false filter'
);

-- Restore it for later tests
UPDATE rim_taxes SET is_deleted = false WHERE id = '00000000-0000-0005-0000-000000000002';

-- ══════════════════════════════════════════════════════════════════════════════
-- Section C: rim_tax_rates
-- ══════════════════════════════════════════════════════════════════════════════

SELECT ok(
  (SELECT COUNT(*)::int FROM rim_tax_rates WHERE tax_id = '00000000-0000-0005-0000-000000000001') = 3,
  'ok 10 — TVA has 3 rates (16% STANDARD, 18% STANDARD future, ZERO)'
);

SELECT ok(
  (SELECT rate FROM rim_tax_rates WHERE id = '00000000-0000-0006-0000-000000000003') = 0,
  'ok 11 — ZERO rate = 0'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_name = 'rim_tax_rates' AND constraint_type = 'UNIQUE'
  ),
  'ok 12 — UNIQUE constraint exists on rim_tax_rates'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM information_schema.check_constraints cc
    JOIN   information_schema.constraint_column_usage cu ON cc.constraint_name = cu.constraint_name
    WHERE  cu.table_name = 'rim_tax_rates' AND cc.check_clause LIKE '%effective_to%'
  ),
  'ok 13 — effective_to > effective_from CHECK constraint exists'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM information_schema.check_constraints cc
    JOIN   information_schema.constraint_column_usage cu ON cc.constraint_name = cu.constraint_name
    WHERE  cu.table_name = 'rim_tax_rates' AND cc.check_clause LIKE '%rate%>=%'
  ),
  'ok 14 — rate >= 0 CHECK constraint exists'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Section D: fn_get_active_tax_rate
-- ══════════════════════════════════════════════════════════════════════════════

SELECT ok(
  fn_get_active_tax_rate('00000000-0000-0005-0000-000000000001'::uuid, '2024-06-15', 'STANDARD') = 16.0000,
  'ok 15 — fn_get_active_tax_rate returns 16% on 2024-06-15 (before 2025 change)'
);

SELECT ok(
  fn_get_active_tax_rate('00000000-0000-0005-0000-000000000001'::uuid, '2025-06-15', 'STANDARD') = 18.0000,
  'ok 16 — fn_get_active_tax_rate returns 18% on 2025-06-15 (after 2025-01-01 change)'
);

SELECT ok(
  fn_get_active_tax_rate('00000000-0000-0005-0000-000000000001'::uuid, '2024-06-15', 'ZERO') = 0.0000,
  'ok 17 — fn_get_active_tax_rate returns 0 for ZERO label'
);

SELECT ok(
  fn_get_active_tax_rate('00000000-0000-0099-0000-000000000099'::uuid, '2024-06-15', 'STANDARD') IS NULL,
  'ok 18 — fn_get_active_tax_rate returns NULL for unknown tax_id'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Section E: rim_tax_groups + members
-- ══════════════════════════════════════════════════════════════════════════════

SELECT ok(
  (SELECT COUNT(*)::int FROM rim_tax_group_members
   WHERE tax_group_id = '00000000-0000-0007-0000-000000000001') = 1,
  'ok 19 — DRC Standard group has exactly 1 member (TVA)'
);

SELECT ok(
  (SELECT COUNT(*)::int FROM rim_tax_group_members
   WHERE tax_group_id = '00000000-0000-0007-0000-000000000002') = 2,
  'ok 20 — India GST group has 2 members (CGST seq=1, SGST seq=2)'
);

SELECT ok(
  (SELECT sequence_no FROM rim_tax_group_members
   WHERE tax_group_id = '00000000-0000-0007-0000-000000000002'
     AND tax_id       = '00000000-0000-0005-0000-000000000004') = 2,
  'ok 21 — SGST has sequence_no = 2 in India GST group'
);

-- Cascade delete: temp group was hard-deleted in DO block; its members should be gone
SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM rim_tax_group_members
    WHERE tax_group_id = '00000000-0000-0007-0000-000000000099'
  ),
  'ok 22 — ON DELETE CASCADE removed members when tax_group was deleted'
);

-- ── Finish ────────────────────────────────────────────────────────────────────
SELECT * FROM finish();

ROLLBACK;
