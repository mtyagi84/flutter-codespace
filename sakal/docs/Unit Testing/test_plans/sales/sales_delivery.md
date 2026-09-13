# Sales Delivery — Test Plan
Route: `/sales/deliveries` | Module: SL — Sales | Feature Code: SL-DEL
Spec doc: none yet in `docs/screens/` | See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
## Create
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| DEL-C01 | Create a delivery against an approved Sales Order/Invoice with deferred dispatch | Pick the source document, fill delivery lines, Save Draft | Saves as DRAFT, no stock/GL effect yet | High | Not Started | |
| DEL-C02 | Partial delivery | Deliver less than the full ordered qty | Remaining qty tracked correctly for a follow-up delivery | High | Not Started | |
| DEL-C03 | Batch/serial-tracked product | Deliver a tracked product | Mandatory batch/serial allocation UI appears (CCC #10) | High | Not Started | |
| DEL-C04 | Missing required field | Leave a required field blank, attempt Save | Blocked with a clear validation message | Med | Not Started | |

## Edit (DRAFT only)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| DEL-E01 | Edit a DRAFT delivery | Change a line qty, Save | Persists correctly | High | Not Started | |
| DEL-E02 | Immutability (CCC #5) | Approve the delivery, then attempt to edit | Blocked — editing an approved document must not be possible | High | Not Started | |

## View / Resume Draft
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| DEL-V01 | Every field reloads exactly as saved | Save a DRAFT with batch/serial lines, close, reopen | All fields including batch/serial allocations reload correctly | High | Not Started | |

## List Screen
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| DEL-L01 | Filter by status | Filter to DRAFT only | Only DRAFT deliveries show | Med | Not Started | |
| DEL-L02 | Status badge reflects real status | Approve one, refresh the list | Badge updates to APPROVED | High | Not Started | |

## Print
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| DEL-P01 | Print an approved delivery | Print | All bound fields + signatures render correctly (per CLAUDE.md's print-support convention) | Med | Not Started | |

## Approve — **1 bug FIXED 2026-09-13, pending redeploy verification**
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| **DEL-A01** | **Save Draft / Approve buttons stay enabled after Approve** | Approve a Sales Delivery, observe the header action buttons immediately after | **Expected**: once APPROVED, both "Save Draft" and "Approve" buttons must become disabled/hidden — CCC #4. | High | **Fixed (commit `a172574`)** | Root cause: `_approveDelivery()` relied entirely on a subsequent `_init()` re-fetch to pick up the new status — a race/transient failure there left `_status` stale at `'DRAFT'`. Fixed by setting `_status = 'APPROVED'` directly in the same `setState` as the success path, matching `grn_entry_screen.dart`'s own already-correct `_approveGrn()`. **Re-test in the app once redeployed, then mark Passed. Also worth spot-checking this exact pattern (relying solely on reload vs. setting status inline) on every other transaction screen's own approve function.** |
| DEL-A02 | Re-clicking Approve after an already-approved document | Click Approve again on an already-approved document | Must be a no-op or a clean "already approved" error, never a duplicate posting/double stock dispatch | High | Not Started | |
| DEL-A03 | Stock actually dispatches on Approve | Approve a deferred-dispatch delivery | `ril_stock_ledger`/`rim_product_location.current_stock` update correctly, COGS posts | High | Not Started | |
| DEL-A04 | Permission-denied (CCC #6) | Approve as a user without the SL-DEL approve right | Denied server-side (`APPROVE_NOT_PERMITTED`), not just UI-hidden | High | Not Started | |
| DEL-A05 | Backdated/period-closed checks | Attempt to approve with a backdated/period-closed date | Blocked per `fn_check_backdate_allowed`/`fn_check_period_open` | Med | Not Started | |

## Cancel
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| DEL-X01 | Cancel a DRAFT delivery | Cancel before approval | Source Sales Order/Invoice's remaining-to-deliver qty is restored | High | Not Started | |
| DEL-X02 | Cancel an APPROVED delivery | Attempt to cancel after approval | Confirm actual supported behavior (likely blocked per immutability — verify, don't assume a reversal path exists) | High | Not Started | |

## Cross-Screen Impact
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| DEL-XS01 | Source document updates | Approve a delivery against a Sales Order | Order's delivered-qty/status reflects it; Open Sales Orders report drops it if fully delivered | High | Not Started | |
| DEL-XS02 | Sales Delivery Register + Pending Deliveries report | Approve a delivery | Moves from Pending Deliveries to the Register correctly — see `reports/sales_reports.md` SDR-01 | High | Not Started | |
| DEL-XS03 | Stock reports reflect dispatch | Run Stock Ledger/Stock Balance for the delivered product | Reflects the outward movement exactly | High | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`. CCC #4 is this screen's headline finding —
once DEL-A01 is fixed, re-verify CCC #4 explicitly on every OTHER transaction
screen in this test plan too, since the same button-state bug could exist
anywhere the same pattern was copied.
