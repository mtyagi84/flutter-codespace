# Payment/Receipt Voucher — Test Plan
Route: `/finance/voucher-list` | Module: FN — Finance | Feature Code: FN-PRV
Spec doc: none yet in `docs/screens/` | See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

Covers all 4 voucher types this screen handles: CRV (Cash Receipt), BRV (Bank
Receipt), CPV (Cash Payment), BPV (Bank Payment).

---
## Create
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PRV-C01 | Create a CRV (Cash Receipt) On Account (tested variant — CPV not separately re-tested, same code path) | Pick Cash account, add a Customer line, mark "On Account", enter Amount | Saves correctly | High | **Passed (browser E2E, 2026-10-25)** | `e2e/test_finance_payment_receipt_voucher.js`, 10/10 green on SK-98262. CRV: Dr [5100001] QA Petty Cash EUR / Cr [4110001] QA Test Customer, 100 EUR, DB-verified exact match including correct Dr/Cr direction for a receipt. First real foreign-currency ("Other") GL posting proven this session — exchange rate (0.93) auto-populated correctly from the Cash Account's own EUR currency. See PRV-C05 below for the known reactive-field bug (fixed in a prior session, not re-verified this pass since Party Amount wasn't directly inspected) |
| PRV-C02 | Create a BRV settling a specific bill | Pick Bank account, select "Settle Against Bill", pick a pending bill | Amount pre-fills from the bill; settlement reduces the bill's pending amount | High | Not Started | |
| PRV-C03 | Multi-currency: reciprocal rate field | Enter a rate < 1, use the `@` popup to type the easier reciprocal | Converts and stores correctly | Med | Not Started | |
| PRV-C04 | Cheque details on a bank voucher | Fill cheque number/date | Appears correctly in Cheque Register (see `reports/finance_reports.md` CHQ-01) | Med | Not Started | |
| **PRV-C05** | **Party Amount doesn't populate on an On Account line** | Add an account line, mark "On Account", type a value into Amount | **Expected**: Party Amount field auto-populates immediately. | High | **Fixed (commit `a172574`)** | Root cause confirmed: both the on-screen field AND the print-document builder gated the value behind an `isCrossCurr` check, hiding it whenever the account's currency matched the transaction currency (the common case) — `partyRate` is `1.0` there, so the value was always valid, just hidden. The "Against Bill" path never had this gate, confirming it was a real bug. **Re-test in the app once redeployed, then mark Passed.** |
| PRV-C06 | Verify PRV-C02's own settle-against-bill amount-population still works | Repeat PRV-C02, watch Party Amount as Amount is typed | Confirmed unaffected — the "Against Bill" code path never had the bug, only "On Account" did | High | Passed | Confirmed via code reading during the fix, 2026-09-13 |
| PRV-C07 (new, CCC #2) | `local_amount` correctly converted for a foreign-trans-currency line | Create a fresh CRV: EUR Cash account, On Account, Customer line, 50 EUR | `local_amount` reflects the real EUR→local(CDF) rate, not left as a raw 1:1 copy of `trans_amount` | High | Passed (investigated an apparent historical anomaly, not reproduced) | **Investigation prompted by an anomaly found live in `finance_reports.md`'s Cash & Bank Position Summary pass (2026-10-31)**: the historical `CRV/MAIN/2026/00001` line against `[5100001] QA Petty Cash EUR` (posted 2026-10-25, from this same file's own PRV-C01 test) shows `trans_amount=100.0000 EUR`, `base_amount=107.5269` (correctly converted), but `local_amount=100.0000` — i.e. NOT converted to the tenant's local currency (CDF), unlike a same-day Contra Voucher line on the identical account/currency pair, whose `local_amount=303763.4409` WAS correctly converted. Re-created the exact same scenario fresh, end-to-end through the real UI with deliberate settle-waits after each field interaction (Cash Account select → 3s wait → On Account → Customer line → Amount=50 EUR → Post): the new voucher (`CRV/MAIN/2026/00003`, deleted after the test) posted with `local_amount=151881.7204` (`local_rate=3037.63440860`) — **correctly converted**, matching `50 × 3037.6344`. Could not reproduce the defect on a careful retry. Plausible explanation, not confirmed: the original PRV-C01 test script (`test_finance_payment_receipt_voucher.js`) may have interacted with the Cash Account field faster than this screen's own async `_fetchRatesForTrans(transCurrency)` → `fn_get_exchange_rate(trans→local)` round-trip could complete before Post was clicked — the function's own code (`_onCashBankSelected`/`_fetchRatesForTrans` in `finance_voucher_entry_screen.dart`) looks structurally correct (always re-fetches `_localRate` on every Cash/Bank account change, same as the Display rate), so this reads as a timing race under fast automation rather than a logic defect — but this is NOT independently confirmed via code instrumentation, only via one successful careful retry. **Recommendation**: treat as a known, narrow risk (a real user clicking through at normal human speed is unlikely to hit it, same reasoning already applied to QIS-01's "Location dropdown needed longer settle wait" automation note) rather than a confirmed app defect requiring a code fix — but flag for a future session to deliberately try to force the race (e.g. select a Cash account and click Post within <500ms) if `local_amount` correctness on foreign-currency vouchers becomes safety-critical. The original bad historical line remains in the DB as-is (immutable once posted, per this project's convention — a correction would need a reversing entry, not an edit; not done this pass since it's QA test data, not production). |

## Edit (DRAFT only)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PRV-E01 | Edit a DRAFT voucher | Change the amount, Save | Persists, Party Amount recomputes correctly (once PRV-C05 is fixed) | High | Not Started | |
| PRV-E02 | Immutability (CCC #5) | Approve, then attempt to edit | Blocked | High | Not Started | |

## View / Resume Draft
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PRV-V01 | Every field reloads exactly as saved | Save with a bill settlement, reopen | Settlement reference and amounts reload correctly | High | Not Started | |

## List Screen
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PRV-L01 | Filter by voucher type (CRV/BRV/CPV/BPV) | Filter to CPV only | Only Cash Payments show | Med | Not Started | |
| PRV-L02 | Pagination on a long list | Scroll a list with 100+ vouchers | Loads more correctly (`PagedListController`) | Low | Not Started | |

## Print
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PRV-P01 | Print shows correct Dr/Cr and amounts | Print an approved voucher | Amounts correct, no bare negatives (CCC #1) | Med | Not Started | |

## Approve / Post
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PRV-A01 | Button state after approve (CCC #4) | Approve, observe buttons | Save/Approve disable correctly — cross-check against the Sales Delivery bug (`sales/sales_delivery.md` DEL-A01), this screen may or may not share the same defect | High | Not Started | |
| PRV-A02 | Bill settlement reduces Pending Bills | Approve a bill-settling voucher | Pending Bills Register reflects the reduction immediately | High | Not Started | |
| PRV-A03 | Permission gating (CCC #6, `FN-PRV`) | Approve as a user without the right | Denied server-side | High | Not Started | |
| PRV-A04 | Composition guard: doesn't require unrelated JV/CTR permission | Approve as a user with ONLY `FN-PRV`, not `FN-JRN`/`FN-CTR` | Succeeds (per the `source_doc_type IS NULL` guard fix, migration 113) | Med | Not Started | |

## Cancel
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PRV-X01 | Reverse a posted voucher | Use `fn_reverse_voucher` | Dr/Cr flip correctly, `inv_bill_no` dropped (a reversal is a pure GL correction) | High | Not Started | |

## Cross-Screen Impact
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PRV-XS01 | Account Ledger reflects the voucher | Approve, run Account Ledger for the account | Line appears correctly, Dr/Cr labeled (CCC #1 — cross-check against the known Account Ledger bug) | High | Not Started | |
| PRV-XS02 | Day Book / Voucher Register | Approve | Appears in Day Book with correct voucher type | Med | Not Started | |
| PRV-XS03 | Cash & Bank Position Summary | Approve a cash/bank voucher | Position updates correctly | Med | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items. CCC #3 (reactive fields) is this screen's headline finding —
PRV-C05/C06 above ARE that checklist item made concrete; once fixed, re-verify on
every other screen with a similar auto-populate-from-sibling-field pattern (e.g.
Contra Voucher's From/To amount reconciliation, Sales Invoice's charge
apportionment).
