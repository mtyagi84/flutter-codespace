# Master Data Reports — Test Plan
Module: AD — Settings | Group: Master Reports | See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

Report template: **Load with no filters (smoke) / Every filter individually / Data
accuracy vs. the master screen / Export & Print / Permission-denied / CCC**.
These 13 reports are all print/export-oriented snapshots of master data (built
2026-08-28, zero new Flutter code, shared `ReportScreen` engine) — lighter test
depth than transaction-derived reports since there's no GL/stock correctness to
verify, mainly "does it match the master screen exactly."

---
## MST-RPT-PRD — Item/Product Master Report
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PRDR-01 | Matches Product Master screen | Create/edit a product, run the report | New/changed product appears with matching field values | High | Not Started | |
| PRDR-02 | Filter by category/brand | Apply a filter | Only matching products show | Med | Not Started | |
| PRDR-03 | Export to Excel/PDF | Export | File opens correctly, data matches | Med | Not Started | |

## MST-RPT-CUS / MST-RPT-SUP — Customer / Supplier Master Report
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PARTYR-01 | Matches Customer/Supplier Master | Create/edit a party, run the report | Matches exactly | High | Not Started | |
| PARTYR-02 | Ledger currency shown (CCC #2) | Run for parties with different ledger currencies | Currency indicated per party | Med | Not Started | |

## MST-RPT-COA / MST-RPT-GRP — Chart of Accounts / Chart of Groups Report
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| COAR-01 | Tree structure matches COA screen | Run for OHADA, INDIAN, and ZAMBIA companies | Indented TABULAR tree matches each standard's real structure | High | Not Started | |
| COAR-02 | New leaf accounts show (2026-09-13 fix) | On a fresh tenant, run after Accounting Setup | Auto-created Stock/COGS/Purchase Accrual leaves appear | Med | Not Started | |

## MST-RPT-ITC — Item Category Master Report
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| ITCR-01 | Tree + flags match Item Categories screen | Create nested categories with flags, run report | Matches exactly | Med | Not Started | |

## MST-RPT-CMN — Common Masters Report
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CMNR-01 | New-tenant starter values appear (2026-09-13 fix) | Fresh tenant, run report | UOM/Brand/Color/reason/category defaults all show | Med | Not Started | |

## MST-RPT-TAX / MST-RPT-TXG — Tax Master / Tax Group Master Report
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| TAXR-01 | New default tax setup appears (2026-09-13, OHADA/ZAMBIA) | Fresh OHADA/ZAMBIA tenant | 16%/0% default tax + group show correctly | High | Not Started | |
| TAXR-02 | Rate history shown correctly | A tax with 2+ date-effective rates | Both rates listed with their effective dates | Med | Not Started | |

## MST-RPT-PYT — Payment Terms Master Report
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PYTR-01 | Matches Payment Terms screen | Create a term, run report | Matches, including installment lines | Med | Not Started | |

## MST-RPT-SEX — Sales Executives Master Report
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SEXR-01 | Matches Sales Executives screen | Create an executive, run report | Matches | Low | Not Started | |

## MST-RPT-CHG — Additional Charges Master Report
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CHGR-01 | ADD vs DEDUCT nature shown correctly | Create both types, run report | Nature clearly distinguished | Med | Not Started | |

## MST-RPT-PRC — Price List Report
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PRCR-01 | Matches Price Master, currency shown (CCC #2) | Create prices in 2+ currencies, run report | Each price shows its own currency correctly | High | Not Started | |
