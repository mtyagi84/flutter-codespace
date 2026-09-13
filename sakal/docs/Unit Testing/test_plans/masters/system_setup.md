# System Setup — Test Plan
Module: AD — Settings | Group: System Setup | See `00_INDEX.md` for the Cross-Cutting Checklist referenced as "CCC #N" below.

Master screen template: **Create / Edit / Deactivate-Reactivate / List+Search+Filter / Cross-Screen Impact / CCC**.

---
## AD-CMP — Company Setup (`/setup/company`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CMP-01 | Edit company name/address/logo and save | Open Company Setup, change fields, Save | Values persist, reload shows new values | High | Not Started | |
| CMP-02 | Base/Local currency shown read-only after transactions exist | Open on a company with posted transactions | Currency fields are locked/disabled, not editable | High | Not Started | |
| CMP-03 | Upload logo | Upload an image, save | Logo appears on print templates (cross-check any transaction print) | Med | Not Started | |
| CMP-04 | CCC #7 Responsive | Open at 400px width | No overflow, fields stack cleanly | Med | Not Started | |

## AD-LOC — Location Setup (`/setup/locations`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| LOC-01 | Create a new location | Add Location, fill required fields, Save | Appears in location list; appears in every screen's Location picker | High | Not Started | |
| LOC-02 | Location Type / Group assignment | Set `inter_location_model`-relevant group | Group shows correctly on Location Groups-aware screens | High | Not Started | |
| LOC-03 | Deactivate a location | Deactivate a location with no open transactions | No longer selectable in new transaction pickers; historical transactions still show it | Med | Not Started | |
| LOC-04 | `is_negative_stock_allowed` / `is_issue_allowed` flags | Toggle flags, verify effect on a stock transaction at that location | Negative-stock/issue behavior matches the flag | High | Not Started | |
| LOC-05 | Cross-Screen: new location visible everywhere | Create a location, open GRN/Sales Invoice/Stock Transfer location pickers | New location appears in all of them immediately | High | Not Started | |

## AD-CUR — Currency Setup (`/setup/currencies`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CUR-01 | Activate a currency | Activate e.g. ZMW | Appears in every currency dropdown app-wide | High | Not Started | |
| CUR-02 | Base/Local currency already active, cannot deactivate | Attempt to deactivate the company's own base currency | Blocked with a clear message | High | Not Started | |

## AD-PDC — Period Close (`/setup/period-close`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PDC-01 | Close a period | Close a past period | `fn_check_period_open` blocks new postings dated in that period, on EVERY transaction screen (spot-check GRN + Journal Voucher) | High | Not Started | |
| PDC-02 | Re-open a period | Re-open a closed period | Postings allowed again | Med | Not Started | |
| PDC-03 | CCC #6 Permission gating | Attempt close as a user without the right | Denied | Med | Not Started | |

## AD-BDC — Backdated Entry Control (`/setup/backdated-entry-control`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| BDC-01 | Disallow backdating for a transaction type | Turn off backdating for e.g. Sales Invoice | Approving a backdated Sales Invoice is blocked (`fn_check_backdate_allowed`) | High | Not Started | |
| BDC-02 | Allow backdating within N days | Set an N-day window | A date within the window is allowed, outside is blocked | Med | Not Started | |

## AD-QIS — Quick Invoice Setup (`/setup/quick-invoice-setup`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| QIS-01 | Assign cash customer per user | Set `cash_customer_id` for a cashier user | That user's Sales Invoice cash sales post to the assigned customer | High | Not Started | |
| QIS-02 | Stock dispatch mode | Toggle IMMEDIATE vs DEFERRED | Sales Invoice line dispatch/COGS behavior matches | High | Not Started | |

## AD-CNT / AD-DIV / AD-CIT — Country Setup, Divisions, Cities
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| GEO-01 | Activate a country | Activate e.g. Zambia | Appears in address country pickers app-wide | Med | Not Started | |
| GEO-02 | Divisions load per country | Open Country Divisions for an activated country | Correct province/state list shows (global `rim_divisions`, `is_system=true`) | Med | Not Started | |
| GEO-03 | Add a City under a Division | Create a city | Appears in address city pickers | Low | Not Started | |

## AD-PDT — Print Templates (`/setup/print-templates`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PDT-01 | Edit a template's letterhead block | Open the designer, move/edit the company_block/title_block row | Preview reflects change; a real document print reflects it | High | Not Started | |
| PDT-02 | Copy a template (`copy_allowed=true`) | Duplicate an existing template | New copy is independently editable, doesn't affect the original | Med | Not Started | |
| PDT-03 | Signature fields bind correctly | Print a document with prepared_by/approved_by set | Both names appear, not blank | High | Not Started | |

## AD-ACT — Accounting Setup (`/setup/accounting`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| ACT-01 | First-time setup, OHADA | Choose OHADA, FY start month, Save | COA seeds correctly; screen locks afterward | High | Not Started | |
| ACT-02 | First-time setup, INDIAN | Choose INDIAN | Correct Indian COA tree seeds | High | Not Started | |
| ACT-03 | First-time setup, ZAMBIA (new 2026-09-13) | Choose ZAMBIA | Zambia IFRS-for-SMEs COA seeds (VAT Payable/Recoverable, PAYE & NAPSA) | High | Not Started | |
| ACT-04 | Locked after seeding | Reopen the screen after COA is seeded | Shows read-only "locked" view, no edit possible | High | Not Started | |
| ACT-05 | Save button placement | Open the screen | Save button is top-right in the header (not bottom of form) — was a known layout bug, confirm fixed | Med | Not Started | |

## MST-CMN — Common Masters (`/master/common-masters`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CMN-01 | Add a value under an existing type (e.g. Brand) | Add "Acme" under Brand | Appears in Product Master's Brand picker | High | Not Started | |
| CMN-02 | New-tenant starter values present (2026-09-13 fix) | Register a brand-new tenant, open Common Masters | UOM (PCS/KG/LTR/BOX), Brand (Generic), Color (N/A), Purchase Return Reason, Stock Adjustment Reason, Incoterm, Customer/Supplier Category all have default rows already | High | Not Started | |
| CMN-03 | Deactivate a value | Deactivate a value in use | No longer selectable for NEW records; existing records unaffected | Med | Not Started | |

## AD-PAYTERM — Payment Terms (`/master/payment-terms`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PYT-01 | Create a PERCENT-only term summing to 100% | Add lines summing to 100% | Saves cleanly | High | Not Started | |
| PYT-02 | PERCENT-only term NOT summing to 100% | Add lines summing to 90% | Blocked with a clear validation message | High | Not Started | |
| PYT-03 | Term appears on Sales Order/Quotation | Select the term on a Sales Order | Term is stored and displays correctly | Med | Not Started | |

---
## Cross-Cutting Checklist reminder
Apply CCC #6 (permission gating) and #7 (responsive) to every screen above at
minimum; most System Setup screens don't have product lines (CCC #9/#10 N/A) or
an Approve/Cancel lifecycle (CCC #4/#5 N/A).
