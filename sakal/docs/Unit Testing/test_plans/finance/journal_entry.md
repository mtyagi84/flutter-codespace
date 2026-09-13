# Journal Entry (Journal Voucher) — Test Plan
Route: `/finance/journal` | Module: FN — Finance | Feature Code: FN-JRN
First manual free-form Dr/Cr entry screen. See `00_INDEX.md` for the
Cross-Cutting Checklist ("CCC #N").

---
## Create
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| JRN-C01 | Balanced Dr/Cr entry | Add lines summing Dr=Cr, Save | Saves as DRAFT | High | Not Started | |
| JRN-C02 | Unbalanced entry blocked | Dr ≠ Cr, attempt Save/Approve | Blocked with a clear message | High | Not Started | |
| JRN-C03 | Auto-tag bill linkage on Customer Dr / Supplier Cr | Debit a Customer account | `inv_bill_no`/`inv_bill_date` auto-tag from Reference No/Date if set, else voucher's own no/date | High | Not Started | |
| JRN-C04 | Optional settle-against-bill checkbox | Credit a Customer / Debit a Supplier | Checkbox appears, optional (never forced) | Med | Not Started | |
| JRN-C05 | Exchange rate field shows real value, not inverted | Enter a rate < 1 | `SakalReciprocalRateField` shows the real rate directly, `@` popup available for the easier reciprocal | Med | Not Started | |
| JRN-C06 | Account picker excludes Cash/Bank | Open the account picker | Cash/Bank accounts NOT selectable here (that's Payment/Receipt Voucher's job) | Med | Not Started | |

## Edit / View / List / Print
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| JRN-E01 | Edit a DRAFT | Change an amount, Save | Persists, still balanced | High | Not Started | |
| JRN-V01 | Reload matches saved state | Save, reopen | Matches | High | Not Started | |
| JRN-L01 | Filter by status | Apply filter | Correct subset | Med | Not Started | |
| JRN-P01 | Print | Print an approved JV | Renders correctly | Med | Not Started | |

## Approve
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| JRN-A01 | Backdate check uses document's own created date, not live today | Create today, approve tomorrow with a same-day trans_date | Not falsely flagged as backdated | High | Not Started | |
| JRN-A02 | Button state after Approve (CCC #4) | Approve | Buttons disable | High | Not Started | |
| JRN-A03 | Direct entry requires `FN-JRN`, auto-posted JV (e.g. from GRN) does NOT | Approve a direct JV without `FN-JRN` | Denied. Approve a GRN with only `PR-GRN` (no `FN-JRN`) | Succeeds (composition guard) | High | Not Started | |

## Reverse
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| JRN-R01 | One-click reversal | Reverse a posted JV via `fn_reverse_voucher` | Every line's Dr/Cr flips, `inv_bill_no` dropped, re-posts under the same voucher type | High | Not Started | |

## Cross-Screen Impact
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| JRN-XS01 | Account Ledger reflects the entry | Approve, run Account Ledger | Line appears, Dr/Cr labeled (CCC #1) | High | Not Started | |
| JRN-XS02 | Bill-tagged line appears in Pending Bills | Debit a Customer with bill tagging | Appears in Pending Bills Register | High | Not Started | |
| JRN-XS03 | Day Book / Voucher Register | Approve | Reflects it with voucher type JV | Med | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.
