-- ============================================================
-- Migration 093: Re-sync group_code/group_name/group_serial_no on
-- ric_master_menus for every existing company, fixing a real bug:
-- the Sales module's sidebar showed "Transactions" twice, each with
-- the full identical feature list underneath.
-- ============================================================
-- Root cause: fn_get_user_menu's groups subquery does
--   SELECT DISTINCT group_code, group_name, group_serial_no
-- then joins each feature's own group_code (NOT group_serial_no) back
-- onto every distinct group row it found. Several migrations added
-- Sales features to the SAME group_code ('SL-TXN') but with
-- DIFFERENT group_serial_no values that drifted independently over
-- time as the module grew (081_sales_quotation.sql used 0,
-- 087_sales_order.sql used 0, 088_quick_invoice_config.sql used 1,
-- and fn_seed_client_modules.sql itself has settled on 1 for all six
-- SL-TXN features) -- each one-off migration's own INSERT ... ON
-- CONFLICT DO UPDATE only ever touched the ONE feature_code it was
-- inserting, never the group's other existing rows, so nothing ever
-- caught the drift. Two distinct (group_code, group_serial_no) pairs
-- for the same "Transactions" group meant fn_get_user_menu's DISTINCT
-- returned two rows, and the (group_code-only) features join then
-- attached the FULL feature list to both -- exactly what showed up
-- twice in the sidebar.
--
-- Fix: fn_seed_client_modules (backend/functions/fn_seed_client_modules.sql)
-- is the single source of truth for every feature's group assignment
-- and is deliberately idempotent/safe to re-run (ON CONFLICT DO UPDATE
-- backfills group_code/group_name/group_serial_no; p_admin_user_id
-- omitted here so this does NOT touch ric_user_menus/grant anything).
-- Re-running it for every existing company re-syncs every currently
-- listed feature_code back onto ONE consistent value per group_code,
-- fixing SL-TXN and pre-empting the same class of drift in any other
-- group this bug may have silently reached (PR-TXN, IN-OPS, FN-TXN,
-- AD-SETG, AD-USMG, SL-MST, AD-MSTG) without having to hand-diagnose
-- each one individually.
--
-- IMPORTANT ORDER: fn_seed_client_modules.sql's CREATE OR REPLACE
-- FUNCTION must be re-run in the Supabase SQL editor BEFORE this
-- migration -- CREATE OR REPLACE isn't picked up automatically, same
-- gotcha as every other function change in this project. Running this
-- migration against the OLD function body would just re-apply the
-- same drifted values and fix nothing.
-- ============================================================

DO $$
DECLARE
    v_company RECORD;
BEGIN
    FOR v_company IN SELECT client_id, id AS company_id FROM ric_companies LOOP
        PERFORM fn_seed_client_modules(v_company.client_id, v_company.company_id);
    END LOOP;
END $$;
