-- ============================================================
-- Migration 139: scope Customer/Supplier Ageing's own Account filter to
-- Customer/Supplier accounts only
-- ============================================================
-- 137_party_ageing_reports.sql's account_id filter (FINANCE_ACCOUNT_PICKER)
-- showed every postable account in the chart, same as Account Ledger's own
-- generic Account filter — correct for Account Ledger (any postable
-- account is a valid ledger subject) but not for Customer/Supplier Ageing,
-- where the picker should only ever offer accounts of the report's own
-- nature. Caught live by the user.
--
-- lookup_source is otherwise meaningless for FINANCE_ACCOUNT_PICKER (it's
-- a DROPDOWN_LOOKUP-only concept, a table/view name) — repurposed here to
-- carry an account_nature restriction instead, consumed by
-- sakal_report_filter_bar.dart's FINANCE_ACCOUNT_PICKER case. No new
-- column needed.
-- ============================================================

UPDATE ric_report_filters f
SET lookup_source = 'Customer'
FROM ric_report_definitions d
WHERE f.report_id = d.id
  AND d.report_key = 'CUSTOMER_AGEING'
  AND f.filter_key = 'account_id';

UPDATE ric_report_filters f
SET lookup_source = 'Supplier'
FROM ric_report_definitions d
WHERE f.report_id = d.id
  AND d.report_key = 'SUPPLIER_AGEING'
  AND f.filter_key = 'account_id';
