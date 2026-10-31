# Cash Receipt — Test Plan
Route: `/sales/receipts` | Module: SL — Sales | Feature Code: SL-RCP
See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| RCP-C01 | Create a receipt settling a specific bill | Pick customer + bill, enter amount | Party Amount populates correctly (CCC #3 — cross-check against the Payment/Receipt Voucher bug, this may be a different code path) | High | Passed | E2E `2026-10-25`: customer `QA Test Customer 48736` correctly showed 4 real pending bills (`SLS/MAIN/2026/00001-3`, `CRN/MAIN/2026/00001`) with accurate Balance (USD) and Balance (CDF) columns. Checked `SLS/MAIN/2026/00001` (500.00 USD / 1,412,500 CDF balance) — Apply field auto-filled the full balance correctly; entered matching Cash Received (Local CDF) 1,412,500, saved as `CREC/MAIN/2026/00001`, auto-approved. |
| RCP-C02 | On-account receipt | Receive without tying to a specific bill | Saves correctly | High | Not Started | |
| RCP-E01 | Edit a DRAFT | Change amount, Save | Persists | High | Not Started | |
| RCP-A01 | Composed CRV voucher posts | Approve | Voucher tagged `source_doc_type='CASH_RECEIPT'`, exempt from unrelated `FN-PRV` permission | High | Passed | `CRV/MAIN/2026/00002` posted: Dr `[5200001]` Main Bank USD base_amount=500.00/party_amount=1,412,500 CDF; Cr `[4110001]` QA Test Customer 48736 500.00 USD — correctly balanced on `base_amount`, multi-currency `party_amount`/`party_currency` resolved per-account exactly per the always-multiply rule. Not independently re-verified that `FN-PRV` permission is bypassed (no restricted-user test this pass), but the composition pattern matches the documented design. |
| RCP-A02 | Button state after Approve (CCC #4) | Approve | Buttons disable | High | Passed | Post-approve screen (`CREC/MAIN/2026/00001`) showed only "Print" in the header, no Save/Approve buttons remaining. |
| RCP-A03 | Permission gating (CCC #6, `SL-RCP`) | Approve without the right | Denied | High | Not Started | |
| RCP-XS01 | Pending Bills reduces | Settle a bill fully | Disappears from Pending Bills | High | Passed | DB-verified: `v_pending_bills` query for `inv_bill_no='SLS/MAIN/2026/00001'` (correctly scoped by `client_id` — see note below) returned zero rows after the receipt was approved, confirming full settlement. |
| RCP-XS02 | Cash Receipt / Collections Register | Approve | Reflects it (`reports/sales_reports.md` CRR-01) | High | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.

### Testing-methodology note, not a product bug
`trans_no`/`inv_bill_no` values like `SLS/MAIN/2026/00001` or `CRV/MAIN/2026/00002` are **not globally unique across tenants** — they're scoped per company. A first DB-verification query against `v_pending_bills`/`rih_finance_headers` without a `client_id`/`company_id` filter silently matched a DIFFERENT tenant's row with the same trans_no (from an earlier POS testing session), producing confusing, wrong-looking data. Always scope verification queries by `client_id` (or `company_id`) explicitly — never rely on `trans_no` alone being unique.
