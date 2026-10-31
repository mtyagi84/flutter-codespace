# Bank Reconciliation — Test Plan
Module: FN — Finance | Group: Bank Reconciliation (4 screens) | Built 2026-08-28,
migrations run and `flutter analyze`/`test` confirmed clean, but **not yet
click-tested end-to-end in the app** — this is the first real pass. See
`00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
## FN-BSF — Bank Statement Format Master (`/finance/bank-statement-formats`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| BSF-01 | Define a CSV column mapping | Map columns for a real bank's CSV export | Saves correctly | High | Passed | E2E `2026-10-25`: created "QA Main Bank USD CSV" format (CSV, mapping Txn No/Date/Description/Debit/Credit/Balance) — saved correctly, immediately available in the Statement Format picker on the Upload screen. |
| BSF-02 | Define an Excel column mapping | Map columns for a bank's XLSX export | Saves correctly | High | Not Started | |
| BSF-03 | Define a PDF format | Map a PDF-based statement format | Saves correctly (PDF parsing is documented as more fragile — test with a real sample) | Med | Not Started | |

## FN-BAC — Bank Accounts (`/finance/bank-accounts`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| BAC-01 | Link a Bank Account to a Chart of Accounts leaf + a Format | Create, Save | Appears in Bank Statement Upload's account picker | High | Passed | E2E `2026-10-25`: linked `[5200001] Main Bank USD` to "QA International Bank" / account 1234567890 — saved, correctly appeared in the Bank Account autocomplete on the New Bank Statement screen (search "Main Bank USD" resolved to "QA International Bank — [5200001] Main Bank USD"). |

## FN-BST — Bank Statement Upload & Review (`/finance/bank-statements`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| BST-C01 | Upload a real CSV statement | Upload, using a configured format | Parses correctly, lines appear for review | High | Passed | E2E `2026-10-25`: 3-line test CSV (one short-format date "10/10" with no year, two full dates, mixed Debit/Credit) uploaded against "QA Main Bank USD CSV" format — banner "Extracted 3 line(s) successfully.", grid showed every line with correct Txn No/Date/Remarks/Debit/Credit/Balance, including the short date correctly inferred as 2026-10-10. Saved as Draft → `BSTMT/MAIN/2026/00001`. DB-verified: `rih_bank_statement_headers` row correct (status DRAFT, period 2026-10-01→2026-10-31, opening_balance 0, closing_balance 897.50); all 3 `rid_bank_statement_lines` rows correct (serial_no/txn_no/txn_date/remarks/debit_amount/credit_amount/running_balance all match the source file exactly; running balance chain 500.00→912.50→897.50 correct). Minor note, not chased as a bug: every line persisted with `is_reviewed=true` immediately on parse, before any explicit review action was taken on screen — worth a closer look if "Review" is meant to be a distinct gate before Approve. |
| BST-C02 | Upload a real Excel statement | Upload | Parses correctly | High | Not Started | |
| BST-C03 | Upload a real PDF statement | Upload | Parses correctly (or a real, clear error if not — a past bug: parse errors were swallowed, fixed `840256b`) | High | Not Started | |
| BST-C04 | Malformed file | Upload a file with a wrong column layout | A REAL, specific parse error surfaces — not a generic swallowed error (regression check for `840256b`) | High | Not Started | |
| BST-A01 | Approve reviewed lines | Review and approve | Lines become available for matching | High | Passed | E2E `2026-10-25`: reopened the DRAFT `BSTMT/MAIN/2026/00001`, clicked "Save & Approve" — status flipped to APPROVED (green badge) in the list, "Bank Statement approved." toast. Confirmed downstream: all 3 lines then appeared as selectable candidates on the Bank Reconciliation Matching screen (see BRM-C00), proving an approved statement's lines are genuinely available for matching. |
| BST-A02 | Button state after Approve (CCC #4) | Approve | Buttons disable | High | Passed | After approval the screen navigated back to the list (no longer on the entry screen at all), so there is no lingering enabled Save/Approve button to click again — functionally equivalent to disabling. |
| BST-UI01 | Row height not cramped | View a long list of statement lines | Readable row height (a past layout bug, fixed alongside `840256b`) | Med | Passed | Grid rows (3 lines) rendered with normal, readable spacing — no cramping observed. |
| BST-UX01 | Period From/To date entry | Open New Statement, set Period From/To | A plain native Flutter DatePicker (calendar grid + toggle-to-text-entry mode), not a plain text field — confirmed working via calendar-day click; the toggled "Enter Date" text-entry sub-mode silently reverted to calendar view and mis-parsed a fast-typed date (10/01/2026 became day 07) during this automated pass — worth a quick manual check whether a real user typing at normal speed hits the same misparse, or if this is purely an automation-speed artifact. | Low | Passed (w/ note) | |

## FN-BRM — Bank Reconciliation Matching (`/finance/bank-reconciliation`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| BRM-C00 | 1-to-1 match, simple case | Select bank account, Load — book entries (open CTR/CRV voucher lines) on the left, bank statement lines on the right, each with a checkbox; select the `CRV/MAIN/2026/00002` book line (Dr 500.00, this session's own Cash Receipt settlement) and the `2026-10-05 Deposit - Cash Receipt` bank line (Cr 500.00); Match button only enables once Selected Book == Selected Bank | Match succeeds, both lines disappear from their respective unmatched lists, Adjusted Book Balance and Adjusted Bank Balance each drop by exactly 500.00, overall Difference unchanged (897.50 before and after, since both sides moved equally) | High | Passed | E2E `2026-10-25`: exactly as expected — "Matched." snackbar, both lines removed from view, balances 1505.03→1005.03 (book) / 607.53→107.53 (bank), Difference stayed 897.50. DB-verified: 2 new `rid_bank_reconciliation_matches` rows sharing one `match_group_id`, one `line_type='BOOK'` (finance_line_id set) + one `line_type='STATEMENT'` (bank_statement_line_id set), both `matched_amount=500.0000`, `match_type='MANUAL'`. |
| BRM-C01 | Many-to-many matching | Match 2 bank lines to 1 ledger entry (or vice versa) | Matches correctly | High | Not Started | Not exercised this pass — the fixture only had one exact 1-to-1 pair available; a genuine many-to-many case needs deliberately constructed data. |
| BRM-C02 | Running-total guardrail | Attempt a match where the running total doesn't balance | Blocked or warned per the documented guardrail | High | Passed | Confirmed structurally during BRM-C00: before both sides summed equal (500.00 = 500.00), the Match button rendered disabled/greyed; it only became clickable once Selected Book exactly equalled Selected Bank. |
| BRM-C03 | Inline quick-entry | Create a missing ledger entry inline during matching | Entry created and immediately available to match against | High | Not Started | |
| BRM-C04 | Unmatch (known open gap — not built) | Attempt to unmatch a completed match | Confirm this is correctly absent (documented open gap, not a bug to report again) | Low | N/A — Not Built | |
| BRM-XS01 | Bank Reconciliation Statement report reflects matching state | Match some lines, run the report | Reconciled/unreconciled split matches what was done here | High | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`. This whole feature is genuinely new and
UNTESTED in the app — treat every scenario above as a first-time real check, not
a regression check, except where explicitly marked as a past bug's regression.
