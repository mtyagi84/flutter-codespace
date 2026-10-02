# Reporting & Audit Trail

## 1. Reporting — plugs into the existing generic reporting engine
No bespoke report screens. Each report below is: one `STABLE` view/function
(`security_invoker = true`, mandatory per CLAUDE.md) aggregating the new POS
tables, plus one `ric_report_definitions` row + its `ric_report_columns` +
`ric_report_filters` (DATE_RANGE, DROPDOWN_LOOKUP on terminal/cashier/shift
via a `v_user_accessible_pos_terminals`-style view) — same recipe as Sales
Register (migration 127) and every reporting-engine module batch already
shipped (migrations 136-176).

| Report | Source |
|---|---|
| Z-Report / Shift Summary | `rih_pos_shifts` joined to `rid_pos_tender_lines`, `rih_pos_payouts`, and sales totals for that shift — opening float, cash sales, non-cash sales by method, payouts, expected vs. counted cash, variance |
| Sales by Cashier/Terminal/Store | `rih_sales_invoices` filtered `pos_shift_id IS NOT NULL`, grouped |
| Payment Method / Currency Totals | `rid_pos_tender_lines` grouped by `tender_method`, `currency_id` |
| Returns by Reason/Cashier | `rih_sales_returns` + the new reason picklist |
| Promotion Usage | `rid_sales_invoice_lines.applied_scheme_id` grouped, with discount value and qualifying-sale count |
| Loyalty Activity | `ril_loyalty_ledger` grouped by `trans_type` |
| Cash Variance | `rih_pos_shifts` filtered `variance <> 0` |
| Voids/Overrides/Approvals | `rih_pos_approval_requests` |
| Offline Sync Exceptions | existing `SyncEngine` failure state, surfaced the same way any other module's sync failures already are |

## 2. Reconciliation
Store-level reconciliation (POS sales vs. tender totals vs. physical cash vs.
card/mobile settlement vs. refunds vs. payouts/drops) is the Z-Report plus the
existing Bank Reconciliation module (migrations 174-176) for the card/mobile
clearing accounts — no new reconciliation engine, just a new source feeding
an existing one.

## 3. Audit trail
`AppLogger` (crash/error visibility) is unrelated to this — audit is a
**business control**, not a debugging log, per CLAUDE.md's own distinction.
New `rih_pos_audit_log` table (append-only, no update/delete GRANT at all —
stricter than every other table in this schema, intentionally, since an audit
log that can be edited isn't one):
```
id, client_id, company_id, actor_user_id -> rim_users,
role_context TEXT,                 -- the role active at the time, for traceability if roles change later
location_id, terminal_id, device_id,
action_code TEXT,                  -- LOGIN, LOGOUT, PRICE_OVERRIDE, DISCOUNT_OVERRIDE, VOID_REQUEST, RETURN,
                                    -- REFUND, CASH_IN, CASH_OUT, PAYOUT, CASH_DROP, SHIFT_OPEN, SHIFT_CLOSE,
                                    -- VARIANCE_APPROVAL, LOYALTY_MANUAL_ADJUSTMENT, DEVICE_BLOCK, DEVICE_UNBIND,
                                    -- CONFIG_CHANGE
reference_doc_type, reference_doc_no,
before_value JSONB, after_value JSONB,
reason TEXT,                       -- mandatory for sensitive overrides
approver_id -> rim_users NULL,
correlation_id UUID,               -- links related operations (e.g. a return + its refund + its loyalty reversal)
created_at
```
Written by the relevant `fn_approve_*`/`fn_save_*` function itself (server-
side, same place every other audit-relevant action in this schema already
originates) — never only from the Flutter client, so an audit record can't be
skipped by a client that simply doesn't call it.

## 4. Notifications (v1 scope: in-app only, no push/SMS infra yet)
Surfaced via the existing in-app mechanisms (snackbar/banner, same
`ErrorPresenter`/`AppLogger` conventions) for: payment uncertain, offline mode
started, pending sync count above a threshold, device blocked, cash variance
above threshold, high-value return/discount requested, negative-stock sale
attempted, shift close blocked by an unresolved condition. Messages follow
CLAUDE.md's existing rule: never a raw exception/ID, always a human-readable
sentence ("Payment not confirmed. No sale has been completed.").
