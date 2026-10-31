# Purchase Return — Test Plan
Route: `/purchase/returns` | Module: PR — Purchase | Feature Code: PR-RET
"Return" and "reverse" are one feature — `reason` is a free-text audit label,
never a code branch. See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
## Create
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PRET-C01 | Return against an unbilled GRN | Pick supplier, pick an unbilled GRN, return lines | Saves as DRAFT | High | Not Started | |
| PRET-C02 | Return against a billed GRN | Pick a billed GRN | Saves as DRAFT | High | Passed | E2E `test_purchase_return.js` 12/12: returned all 10 units of the Phase 3 GRN (already billed via Phase 3's Purchase Bill test) — correctly offered and selectable despite being billed, matching the documented "billed or not" rule. Posted as `SDN/MAIN/2026/00001`: Dr Supplier 500 (debit note, reduces payable) / Cr Stock Account 500, balanced. Stock: `current_stock=0` (10 received - 10 returned), `ril_stock_ledger` row `trans_type=PURCHASE_RETURN, qty_change=-10`. |
| PRET-UI01 | **Found live** — Return Qty field's pre-filled display isn't bound into form state until touched | Pick a GRN, immediately Save Draft without clicking into the Return Qty field | Save Draft incorrectly rejected with "Enter a return quantity for at least one line." despite the field visibly showing the GRN's pre-filled qty (10.00) | Med | Found, workaround confirmed | Confirmed live: the Return Qty Pack cell shows the correct value immediately after picking a GRN, but Save Draft still treats it as unset. Clicking into the field, re-typing the same value, and tabbing out fixes it before Save. This is a real UX gap (a user who trusts the visible pre-fill and clicks Save immediately would hit a confusing, inaccurate error) — not confirmed whether it affects every line or only the first, nor whether a non-zero-but-unedited DISCOUNT/RATE field has the same gap. Worth a dedicated Flutter-side look (likely a controller not syncing with the row model's initial value) in a follow-up session. |
| PRET-C03 | Mixed billed + unbilled in one return | Pick both an unbilled and a billed GRN | Both allowed in one document | High | Not Started | |
| PRET-C04 | Reason value from Common Masters | Pick a Purchase Return Reason | Default values present on a fresh tenant (2026-09-13 fix) | Med | Not Started | |
| PRET-C05 | Batch/serial mandatory allocation | Return a tracked product | Mandatory allocation from what this specific GRN line actually received (stricter than GRN's own free-text entry) | High | Not Started | |
| PRET-C06 | PO qty_received rolls back | Return goods received against a PO | PO's `qty_received` rolls back correctly regardless of `p_reopen_po` | High | Not Started | Not testable with this session's data — the Phase 3 GRN was DIRECT mode (no PO link), so `qty_received` was never incremented in the first place. Needs an AGAINST_PO GRN first. |

## Edit / View / List / Print
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PRET-E01 | Edit a DRAFT | Change qty, Save | Persists | High | Not Started | |
| PRET-V01 | Reload matches saved state | Save, reopen | Matches | High | Not Started | |
| PRET-L01 | Filter by status | Apply filter | Correct subset | Med | Not Started | |
| PRET-P01 | Print | Print an approved return | Renders correctly | Med | Not Started | |

## Approve
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PRET-A01 | Unbilled line posts a JV (reverses provisional accrual) | Approve an unbilled-only return | JV posts correctly | High | Not Started | |
| PRET-A02 | Billed line posts an SDN (Supplier Debit Note) | Approve a billed-only return | SDN posts, Supplier Dr'd in aggregate | High | Not Started | |
| PRET-A03 | Mixed return posts BOTH under one `source_doc_no` | Approve a mixed return | Both vouchers tagged with the same source doc, both visible in Posted Journal Entries | High | Not Started | |
| PRET-A04 | Negative stock blocked for tracked products | Attempt a return that would take a batch/serial negative | Blocked, full stop | High | Not Started | |
| PRET-A05 | Button state after Approve (CCC #4) | Approve | Buttons disable | High | Not Started | |
| PRET-A06 | Permission gating (CCC #6, `PR-RET`) | Approve without the right | Denied | High | Not Started | |

## Cross-Screen Impact
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PRET-XS01 | Purchase Return Register | Approve | Reflects both JV and SDN correctly (`reports/purchase_reports.md`) | High | Not Started | |
| PRET-XS02 | Stock reports | Approve | Outward movement reflected correctly | High | Not Started | |
| PRET-XS03 | PO reopens if requested | Approve with `p_reopen_po=true` | PO status recomputes to PARTIALLY_RECEIVED | Med | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.
