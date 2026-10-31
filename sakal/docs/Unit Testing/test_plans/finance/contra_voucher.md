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
| CTR-C04 | trans_currency = FROM account's currency | Transfer between two different-currency accounts | Voucher's `trans_currency` = the FROM account's own currency | Med | Passed | E2E `test_finance_contra_voucher.js` 10/10: Cr [5100001] QA Petty Cash EUR 100 EUR / Dr [5200001] Main Bank USD, DB-verified both lines' `trans_currency='EUR'` (the FROM account's currency), `base_amount=107.5269` each, balanced. Posted as `CTR/MAIN/2026/00001`, `is_posted=true`. |
| CTR-C05 | System rate is read-only and labelled | Pick CDF From, USD To | "Exchange Rate (system)" card under Reference No/Date shows "1 USD = 2,825.00 CDF"; no editable rate field anywhere | High | Not Started | |
| CTR-C06 | Exchange loss | 282,500 CDF → 95 USD | Difference row "Exchange Loss / Transfer Charge (Debit)" showing `5.00 USD · 14,125.00 CDF`; Exchange Gain/Loss account defaulted; Save posts 3 lines balanced on base_amount | High | Not Started | |
| CTR-C07 | Exchange gain | 282,500 CDF → 102 USD | "Exchange Gain (Credit)" `2.00 USD · 5,650.00 CDF`; 3rd line is CR | High | Not Started | |
| CTR-C08 | Exact system rate | 282,500 CDF → 100 USD | No difference row; 2 lines posted | High | Passed (variant currencies) | Same E2E run as CTR-C04, using EUR→USD instead of CDF→USD: accepted the system-suggested "Amount Received" (107.5269 USD for 100 EUR) with no manual edit — exactly at system rate, no 3rd difference/gain-loss line. DB confirms exactly 2 lines, balanced. The CDF-specific pairing (C06/C07/C09/C11/C12, needing a real gap) not yet separately exercised. |
| CTR-C09 | Same-currency fee | 100 USD → 98 USD | "Transfer Charge" 2.00 USD, no default account; Save blocked until an account is picked | High | Not Started | |
| CTR-C10 | Missing rate blocks Save | Pick a voucher date with no USD/CDF rate | Red message pointing to Finance → Exchange Rates + Retry; Save shows it and does not post at rate 1 | High | Not Started | |
| CTR-C11 | Typo warning | 282,500 CDF → 950 USD | Amber ">5% off system rate" warning | Low | Not Started | |
| CTR-C12 | Reset to system rate | Edit Amount Received, click Reset | Amount Received returns to From × system rate | Med | Not Started | |
| CTR-U01 | Initial focus & tab order | Open a new voucher | Cursor in Reference No; Tab shows a visible ring on Reference Date; Enter opens picker; after picking, focus moves to From account | High | Not Started | |
| CTR-U02 | Top margin | Open a new voucher | Voucher No/Date do not touch the top bar | Low | Not Started | |

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
