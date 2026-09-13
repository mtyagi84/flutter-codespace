# Payment/Receipt Voucher — Test Plan
Route: `/finance/voucher-list` | Module: FN — Finance | Feature Code: FN-PRV
Spec doc: none yet in `docs/screens/` | See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

Covers all 4 voucher types this screen handles: CRV (Cash Receipt), BRV (Bank
Receipt), CPV (Cash Payment), BPV (Bank Payment).

---
## Create
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PRV-C01 | Create a CPV (Cash Payment) On Account | Pick Cash account, add a Supplier line, mark "On Account", enter Amount | Saves correctly | High | Not Started | See PRV-C05 below for the known reactive-field bug |
| PRV-C02 | Create a BRV settling a specific bill | Pick Bank account, select "Settle Against Bill", pick a pending bill | Amount pre-fills from the bill; settlement reduces the bill's pending amount | High | Not Started | |
| PRV-C03 | Multi-currency: reciprocal rate field | Enter a rate < 1, use the `@` popup to type the easier reciprocal | Converts and stores correctly | Med | Not Started | |
| PRV-C04 | Cheque details on a bank voucher | Fill cheque number/date | Appears correctly in Cheque Register (see `reports/finance_reports.md` CHQ-01) | Med | Not Started | |
| **PRV-C05** | **Party Amount doesn't populate on an On Account line** | Add an account line, mark "On Account", type a value into Amount | **Expected**: Party Amount field auto-populates immediately. | High | **Fixed (commit `a172574`)** | Root cause confirmed: both the on-screen field AND the print-document builder gated the value behind an `isCrossCurr` check, hiding it whenever the account's currency matched the transaction currency (the common case) — `partyRate` is `1.0` there, so the value was always valid, just hidden. The "Against Bill" path never had this gate, confirming it was a real bug. **Re-test in the app once redeployed, then mark Passed.** |
| PRV-C06 | Verify PRV-C02's own settle-against-bill amount-population still works | Repeat PRV-C02, watch Party Amount as Amount is typed | Confirmed unaffected — the "Against Bill" code path never had the bug, only "On Account" did | High | Passed | Confirmed via code reading during the fix, 2026-09-13 |

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
