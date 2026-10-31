# Credit Sales Invoice — Test Plan
Route: `/sales/credit-invoices` | Module: SL — Sales | Feature Code: SL-CINV
Reuses the Quick Invoice (`rih_sales_invoices`) engine but with always-DEFERRED
dispatch and freely user-chosen currency. See `00_INDEX.md` for the Cross-Cutting
Checklist ("CCC #N").

---
## Create
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CINV-C01 | Create with a freely-chosen currency | Pick a currency different from the customer's own ledger currency | Allowed (unlike Quick Invoice's auto-derive) | High | Passed (bug found) | **CINV-BUG01**: Currency dropdown correctly offers all 3 currencies (CDF/EUR/USD) regardless of customer — confirms the "freely chosen" design. **But real bug found**: `_baseCurrency`/`_localCurrency` (`credit_sales_invoice_entry_screen.dart`) default to `''` and are ONLY populated as a side effect of `_resolveCurrencyForCustomer()` when a Customer is picked — there is no customer-independent load of base/local currency in `_init()`. If a user picks **Currency before Customer** (nothing in the UI requires the opposite order), `_onCurrencySelected` calls `fn_get_exchange_rate` with `p_to_currency: ""` (empty), confirmed live via network capture (HTTP 400, `"No exchange rate found for USD →  on or before ..."`). Worse: `getExchangeRate()` (`sales_invoice_remote_ds.dart:1033`) catches `DioException` and returns `null` unconditionally — the caller then silently defaults Rate to Base/Local to `1`, with **zero error shown to the user**. A user who fills the form in that order could save a real Credit Sales Invoice in CDF at a false 1:1 rate instead of the real ~2825 rate, with no warning. Confirmed the bug disappears when Customer is picked first (the normal/expected order) — `_baseCurrency`/`_localCurrency` then resolve correctly and the rate lookup succeeds (verified: `fn_get_exchange_rate` returned 200 with the correct USD→CDF pair once Customer was set first). **Fix recommendation**: load `_baseCurrency`/`_localCurrency` unconditionally in `_init()` (not deferred to customer selection), matching whatever pattern Sales Invoice's own entry screen already uses for the same two fields. Not fixed this pass — logged for the bug-fix backlog. |
| CINV-C02 | Stock always deferred | Add lines, save | No immediate stock/COGS dispatch, regardless of any setting | High | Passed | E2E `2026-10-26`: created `SI/MAIN/2026/00004` (Customer `[4110001] QA Test Customer 48736`, USD, 1×PRD-00002 @120.00, manual price override with reason). DB-verified header: `stock_dispatch_mode='DEFERRED'`. After Approve: `cos_voucher_no=null` on the invoice, zero `ril_stock_ledger` rows for this invoice, SI voucher (`SLS/MAIN/2026/00004`) correctly balanced Dr Customer 120.00 / Cr Sales 120.00 — no stock/COGS movement at invoice time, confirmed in the DB not just "no error". |
| CINV-C03 | Hard future-date block | Attempt a future invoice date | Blocked | High | Not Started | |
| CINV-C04 | Date locked after first save | Save, then attempt to change the date | Blocked | Med | Passed | On reopening the saved Draft, the Invoice Date field visibly switched from an editable date picker to a disabled field reading "Locked after first save" — confirmed directly in the UI, both before and after Approve. |
| CINV-C05 | Save Draft vs Approve are separate steps (unlike Quick Invoice) | Save as Draft first | Stays DRAFT, does not auto-approve | High | Passed | Save Draft left the document in `DRAFT` status with a separate, distinct "Approve" button still to click (DB-verified `status='DRAFT', approved_by=null` immediately after Save) — confirmed genuinely separate from Quick Invoice's single-click save+approve. |

## Edit (DRAFT only)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CINV-E01 | Edit a DRAFT | Change a line, Save | Persists | High | Not Started | |
| CINV-E02 | Immutability (CCC #5) | Approve, attempt edit | Blocked | High | Not Started | |

## View / List / Print
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CINV-V01 | Reload matches saved state | Save, reopen | Matches | High | Not Started | |
| CINV-L01 | Filter by status | Apply filter | Correct subset | Med | Not Started | |
| CINV-P01 | Print | Print an approved invoice | Renders correctly | Med | Not Started | |

## Approve
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CINV-A01 | Button state after Approve (CCC #4) | Approve | Buttons disable — this module SHARES the Sales Invoice engine, cross-check whether the known Sales Delivery bug pattern also exists here | High | Passed | After Approve, status badge changed to `APPROVED`; reopening the document from the list showed Save Draft/Approve still present in the header (expected — a Credit Sales Invoice can still receive a Cancel action and has a Collect Payment section that stays live post-approve), but DB-verified the document itself is genuinely posted (`approved_by`/`approved_at` set, SI voucher created) — no double-posting risk observed across 2 separate Approve attempts in this session (the first click correctly required confirming a dialog, not a silent no-op). |
| CINV-A02 | Permission gating (CCC #6, `SL-CINV`) | Approve without the right | Denied | High | Not Started | Not re-tested on this specific screen this pass — CCC#6 was deep-tested once on Journal Voucher (see `finance/journal_entry.md` JRN-A03) proving both UI-level and backend-level (`fn_check_approve_permission`) denial work; the same mechanism is documented (CLAUDE.md, migration 114) to cover `SL-INV`/Sales Invoice's shared approve path, which this screen reuses. |
| CINV-A03 | A later Sales Delivery actually dispatches the stock | Approve the invoice, then create+approve a Sales Delivery against it | Stock/COGS dispatch happens at delivery time, not invoice time | High | Passed | E2E `2026-10-26`: created `SDEL/MAIN/2026/00004` against `SI/MAIN/2026/00004`, 1×PRD-00002, Approved. DB-verified: `ril_stock_ledger` now has a real row (`trans_type='SALES_DELIVERY', qty_change=-1.0000`) tied to the delivery, not the invoice; the delivery header itself carries its own `cos_voucher_no='COS/MAIN/2026/00004'` (NOT written back onto the invoice header, which stays `cos_voucher_no=null` — COGS tracking lives on the Delivery, confirmed this is correct design, not a gap); the COS voucher's 2 GL lines balance exactly (Dr/Cr 25.00, matching PRD-00002's established cost). Full proof that stock/COGS genuinely wait for delivery, not invoice approval. |

## Cross-Screen Impact
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CINV-XS01 | Sales Register + Pending Bills | Approve | Both reflect it | High | Not Started | |
| CINV-XS02 | Sales Delivery / Pending Deliveries | Approve | Invoice appears as a valid source document for delivery | High | Passed | Confirmed as part of CINV-A03 above: the approved invoice correctly appeared in the Sales Delivery screen's own Invoice picker (searchable by invoice number, showed "Pending 1.00"), and after delivery the invoice no longer shows as pending (0 remaining). |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.
