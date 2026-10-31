# Inventory Masters — Test Plan
Module: AD — Settings | Group: Inventory Masters | See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
## MST-PRD — Product Master (`/master/products`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PRD-01 | Create a product, NONE tracking | Fill required fields, `tracking_type=NONE`, Save | Appears in every product picker; no batch/serial prompts on transactions | High | **Passed (browser E2E, 2026-10-24)** | `e2e/test_master_product_master.js`, 7/7 green on SK-98262. Minimal-field product (Code auto-generated, Name, Base UOM=PCS) saved, DB-verified active/not-deleted. **Noted, not a bug**: picking Base UOM alone does NOT create a `rim_product_uom` row — that table is only populated via this screen's separate "Multiple Barcode"/UOM-rows section (confirmed by reading `_save()`/`_saveUoms()` directly). Matches the already-known `rim_product_uom≠base_uom_id` fallback gap already mitigated in Price Master/Sales per project memory — not a new finding |
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
| ITC-01 | Create a category at Level 1 | Add a category | Appears in Product Master's category picker | High | **Passed (browser E2E, 2026-10-24)** | `e2e/test_master_item_categories.js`, 6/6 green on SK-98262. Category created at Level 1, DB-verified `parent_id=null`. Product Master picker reflection not re-tested this pass (Product Master's own test ran before this category existed) |
| ITC-02 | Child category inherits parent flags | Create a child under a flagged parent | Flags pre-fill from parent | Med | Not Started | |
| ITC-03 | Cascade flag change to children | Edit a parent's flag, choose "cascade" | All descendants update | Med | Not Started | |
| ITC-04 | "General" starter category exists (2026-09-13 fix) | Fresh tenant, open Item Categories | A "General" Level-1 category already exists with standard flags | Med | **Passed (direct DB check, 2026-10-24)** | Confirmed via the same test script's DB pre-check — `General` exists with `parent_id=null` |

## AD-PCS — Product Category Level Setup (`/setup/category-levels`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PCS-01 | Configure level count/labels | Set 2 levels with custom labels | Item Categories screen reflects the new level structure | Med | **Passed (browser E2E, 2026-10-24)** | `e2e/test_setup_category_levels.js`, 4/4 green on SK-98262. Level 1 ("Category") already seeded by the starter kit; added Level 2 ("Sub-Category"), DB-verified. Item Categories screen reflection not re-tested this pass |

## AD-PGS — Product Flag Types (`/setup/product-flag-types`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PGS-01 | Load Defaults button | Click Load Defaults on a fresh tenant | The 8 standard flags appear (is_saleable, is_purchasable, etc.) | Med | **Passed (browser E2E, 2026-10-24)** | `e2e/test_setup_product_flag_types.js`, 5/5 green on SK-98262. All 8 standard flags already present via the new-tenant starter kit (Load Defaults button not clicked — defaults pre-seeded, confirmed via screen + DB) |
| PGS-02 | Add a custom flag | Add a new flag_key | Appears on both Item Categories and Product Master's flag list | Low | **Passed (browser E2E, 2026-10-24)** | Custom flag `is_qa_test_84933` created, DB-verified. Cross-screen appearance on Item Categories/Product Master not re-verified this pass |

## IN-DCA — Consumption Area Setup (`/inventory/department-consumption-areas`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| DCA-01 | Create a Consumption Area under a Department, link an account | Fill fields, Save | Material Requisition/Issue's Department→Consumption Area cascading picker shows it, resolves to that expense account | High | **Passed (browser E2E, 2026-10-24)** | `e2e/test_inventory_consumption_area_setup.js`, 7/7 green on SK-98262 (prerequisite Department + Consumption Area common-master values created via `test_setup_common_masters_dept_consumption.js`). Linked to `[5800] Internal Transfers`, DB-verified. Material Requisition/Issue's own cascading picker reflection deferred to Phase 4 (Inventory transactions) |
| DCA-02 | Uniqueness: one area, one account, company-wide | Attempt to link the same Consumption Area under a 2nd Department | Blocked (partial unique index on consumption_area_id alone) | Med | Not Started | |

---
## Cross-Cutting Checklist reminder
CCC #9 (Pack/Loose + Barcode) and #10 (Batch/Serial) are primarily DEFINED here
(on the product) but must be verified on every TRANSACTION screen that uses this
product — cross-reference back to each transaction file when testing a specific
product's behavior end-to-end.
