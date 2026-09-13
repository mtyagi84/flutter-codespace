# Bank Reconciliation — Test Plan
Module: FN — Finance | Group: Bank Reconciliation (4 screens) | Built 2026-08-28,
migrations run and `flutter analyze`/`test` confirmed clean, but **not yet
click-tested end-to-end in the app** — this is the first real pass. See
`00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
## FN-BSF — Bank Statement Format Master (`/finance/bank-statement-formats`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| BSF-01 | Define a CSV column mapping | Map columns for a real bank's CSV export | Saves correctly | High | Not Started | |
| BSF-02 | Define an Excel column mapping | Map columns for a bank's XLSX export | Saves correctly | High | Not Started | |
| BSF-03 | Define a PDF format | Map a PDF-based statement format | Saves correctly (PDF parsing is documented as more fragile — test with a real sample) | Med | Not Started | |

## FN-BAC — Bank Accounts (`/finance/bank-accounts`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| BAC-01 | Link a Bank Account to a Chart of Accounts leaf + a Format | Create, Save | Appears in Bank Statement Upload's account picker | High | Not Started | |

## FN-BST — Bank Statement Upload & Review (`/finance/bank-statements`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| BST-C01 | Upload a real CSV statement | Upload, using a configured format | Parses correctly, lines appear for review | High | Not Started | |
| BST-C02 | Upload a real Excel statement | Upload | Parses correctly | High | Not Started | |
| BST-C03 | Upload a real PDF statement | Upload | Parses correctly (or a real, clear error if not — a past bug: parse errors were swallowed, fixed `840256b`) | High | Not Started | |
| BST-C04 | Malformed file | Upload a file with a wrong column layout | A REAL, specific parse error surfaces — not a generic swallowed error (regression check for `840256b`) | High | Not Started | |
| BST-A01 | Approve reviewed lines | Review and approve | Lines become available for matching | High | Not Started | |
| BST-A02 | Button state after Approve (CCC #4) | Approve | Buttons disable | High | Not Started | |
| BST-UI01 | Row height not cramped | View a long list of statement lines | Readable row height (a past layout bug, fixed alongside `840256b`) | Med | Not Started | |

## FN-BRM — Bank Reconciliation Matching (`/finance/bank-reconciliation`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| BRM-C01 | Many-to-many matching | Match 2 bank lines to 1 ledger entry (or vice versa) | Matches correctly | High | Not Started | |
| BRM-C02 | Running-total guardrail | Attempt a match where the running total doesn't balance | Blocked or warned per the documented guardrail | High | Not Started | |
| BRM-C03 | Inline quick-entry | Create a missing ledger entry inline during matching | Entry created and immediately available to match against | High | Not Started | |
| BRM-C04 | Unmatch (known open gap — not built) | Attempt to unmatch a completed match | Confirm this is correctly absent (documented open gap, not a bug to report again) | Low | N/A — Not Built | |
| BRM-XS01 | Bank Reconciliation Statement report reflects matching state | Match some lines, run the report | Reconciled/unreconciled split matches what was done here | High | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`. This whole feature is genuinely new and
UNTESTED in the app — treat every scenario above as a first-time real check, not
a regression check, except where explicitly marked as a past bug's regression.
