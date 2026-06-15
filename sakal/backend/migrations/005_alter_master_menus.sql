-- ============================================================
-- 005_alter_master_menus.sql
-- Adds group columns to ric_master_menus for 3-level sidebar.
-- Groups are visual sections within a module (no separate table).
-- Run after 004_menus_and_modules.sql
-- ============================================================

alter table ric_master_menus
    add column if not exists group_code      text,
    add column if not exists group_name      text,
    add column if not exists group_serial_no integer not null default 0;

-- Backfill existing rows (if fn_seed_client_modules was already run)
update ric_master_menus set group_code = 'AD-SETG', group_name = 'System Setup',    group_serial_no = 0 where feature_code in ('AD-CMP', 'AD-LOC', 'AD-CUR');
update ric_master_menus set group_code = 'AD-USMG', group_name = 'User Management', group_serial_no = 1 where feature_code in ('AD-USR', 'AD-PRM');
update ric_master_menus set group_code = 'SL-TXN',  group_name = 'Transactions',    group_serial_no = 0 where feature_code in ('SL-INV', 'SL-RET', 'SL-RCP');
update ric_master_menus set group_code = 'PR-TXN',  group_name = 'Transactions',    group_serial_no = 0 where feature_code in ('PR-PO', 'PR-GRN', 'PR-INV', 'PR-PAY');
update ric_master_menus set group_code = 'IN-OPS',  group_name = 'Operations',      group_serial_no = 0 where feature_code in ('IN-STK', 'IN-TRF', 'IN-ADJ');
update ric_master_menus set group_code = 'FN-TXN',  group_name = 'Transactions',    group_serial_no = 0 where feature_code in ('FN-JRN', 'FN-CBK');
update ric_master_menus set group_code = 'FN-RPT',  group_name = 'Reports',         group_serial_no = 1 where feature_code in ('FN-TRB', 'FN-PNL', 'FN-BSH');
