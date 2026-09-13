# Inventory Masters — Test Plan
Module: AD — Settings | Group: Inventory Masters | See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
## MST-PRD — Product Master (`/master/products`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PRD-01 | Create a product, NONE tracking | Fill required fields, `tracking_type=NONE`, Save | Appears in every product picker; no batch/serial prompts on transactions | High | Not Started | |
| PRD-02 | Create a BATCH-tracked product | `tracking_type=BATCH`, Save | GRN/Sales/Adjustment screens show batch entry/picker for this product (CCC #10) | High | Not Started | |
| PRD-03 | Create a SERIAL-tracked product | `tracking_type=SERIAL`, Save | Screens show serial entry/picker (CCC #10) | High | Not Started | |
| PRD-04 | BATCH_WITH_EXPIRY + manufacturing date | Create such a product, GRN it in | Expiry date AND manufacturing date fields both appear on the new-lot entry | Med | Not Started | |
| PRD-05 | Barcode / part number | Set a barcode, scan it on GRN | Product resolves correctly, barcode is saved onto the transaction line traceably (CCC #9) | Med | Not Started | |
| PRD-06 | UOM conversions | Set a base UOM + a pack UOM with a conversion factor | Qty Pack/Qty Loose split correctly on transaction lines (CCC #9) | High | Not Started | |
| PRD-07 | Deactivate a product | Deactivate | No longer selectable for NEW transaction lines; historical lines unaffected | Med | Not Started | |
| PRD-08 | Excel bulk upload | Not built yet — flag as known gap, do not test | N/A | Low | N/A — Not Built | |

## MST-ITC — Item Categories (`/master/item-categories`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| ITC-01 | Create a category at Level 1 | Add a category | Appears in Product Master's category picker | High | Not Started | |
| ITC-02 | Child category inherits parent flags | Create a child under a flagged parent | Flags pre-fill from parent | Med | Not Started | |
| ITC-03 | Cascade flag change to children | Edit a parent's flag, choose "cascade" | All descendants update | Med | Not Started | |
| ITC-04 | "General" starter category exists (2026-09-13 fix) | Fresh tenant, open Item Categories | A "General" Level-1 category already exists with standard flags | Med | Not Started | |

## AD-PCS — Product Category Level Setup (`/setup/category-levels`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PCS-01 | Configure level count/labels | Set 2 levels with custom labels | Item Categories screen reflects the new level structure | Med | Not Started | |

## AD-PGS — Product Flag Types (`/setup/product-flag-types`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PGS-01 | Load Defaults button | Click Load Defaults on a fresh tenant | The 8 standard flags appear (is_saleable, is_purchasable, etc.) | Med | Not Started | |
| PGS-02 | Add a custom flag | Add a new flag_key | Appears on both Item Categories and Product Master's flag list | Low | Not Started | |

## IN-DCA — Consumption Area Setup (`/inventory/department-consumption-areas`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| DCA-01 | Create a Consumption Area under a Department, link an account | Fill fields, Save | Material Requisition/Issue's Department→Consumption Area cascading picker shows it, resolves to that expense account | High | Not Started | |
| DCA-02 | Uniqueness: one area, one account, company-wide | Attempt to link the same Consumption Area under a 2nd Department | Blocked (partial unique index on consumption_area_id alone) | Med | Not Started | |

---
## Cross-Cutting Checklist reminder
CCC #9 (Pack/Loose + Barcode) and #10 (Batch/Serial) are primarily DEFINED here
(on the product) but must be verified on every TRANSACTION screen that uses this
product — cross-reference back to each transaction file when testing a specific
product's behavior end-to-end.
