# Contra Voucher — Test Plan
Route: `/finance/contra` | Module: FN — Finance | Feature Code: FN-CTR
Cash↔Cash / Bank↔Bank / deposit / withdrawal. Modeled on Tally's F4. See
`00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
## Create
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CTR-C01 | Simple same-currency transfer | From Cash to Bank, same currency, equal amounts | Saves cleanly, no gain/loss line | High | Not Started | |
| CTR-C02 | From/To amounts don't reconcile — real gap | Enter different From/To amounts at the current rate | Gap auto-computed live, offered as an optional 3rd line (default `EXCHANGE_GAIN_LOSS_ACCOUNT`) | High | Not Started | |
| CTR-C03 | From/To swap, FormField key: bug regression | Swap From and To accounts | Both fields correctly update their displayed value (a documented `key: ValueKey(...)` gotcha on `SakalAutocomplete`) | Med | Not Started | |
| CTR-C04 | trans_currency = FROM account's currency | Transfer between two different-currency accounts | Voucher's `trans_currency` = the FROM account's own currency | Med | Not Started | |

## Edit / View / List / Print
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CTR-E01 | Edit a DRAFT | Change an amount, Save | Persists | High | Not Started | |
| CTR-V01 | Reload matches saved state | Save, reopen | Matches | High | Not Started | |
| CTR-L01 | Filter by status | Apply filter | Correct subset | Med | Not Started | |
| CTR-P01 | Print | Print an approved contra | Renders correctly | Med | Not Started | |

## Approve / Reverse
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CTR-A01 | Button state after Approve (CCC #4) | Approve | Buttons disable | High | Not Started | |
| CTR-A02 | Direct entry requires `FN-CTR` | Approve without the right | Denied | High | Not Started | |
| CTR-R01 | One-click reversal | Reverse via `fn_reverse_voucher` | Correctly reverses both legs | Med | Not Started | |

## Cross-Screen Impact
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CTR-XS01 | Cash & Bank Position Summary | Approve | Both accounts' positions update correctly | High | Not Started | |
| CTR-XS02 | NOT counted as a real cash-flow event | Approve, run Cash Flow report | Cash↔Bank transfer is excluded from the Cash Flow statement (documented exclusion rule) | High | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.
