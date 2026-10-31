# Sales Quotation — Test Plan
Route: `/sales/quotations` | Module: SL — Sales | Feature Code: SL-QUO
Spec doc: `docs/screens/sales_quotation.md` | See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").
Existing informal notes: `docs/Unit Testing/Sales Quotation.md` has 15 free-text bug/UX notes — fold in as regression cases as this file is worked through.

---
## Create
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| QUO-C01 | Create for an existing Customer | Pick customer, add lines, Save | Saves as DRAFT | High | Passed | E2E `2026-10-25`: Customer `[4110001] QA Test Customer 48736`, Currency USD, line PRD-00002 Qty 5 × Rate 100 = 500.00, saved as `SQ/MAIN/2026/00001` DRAFT correctly. |
| QUO-C02 | Create for a Prospect (no customer_id) | Type party name/phone/email/address directly | Saves with `customer_type=PROSPECT`, `party_*` fields populated | High | Not Started | |
| QUO-C03 | Item-wise charge apportionment | Add a charge, verify per-line `charge_amount`/`landed_amount` | Apportioned correctly by value | Med | Not Started | |
| QUO-C04 | Incoterm / Payment Term selection | Pick both | Save correctly, appear on print | Low | Not Started | |

## Edit (DRAFT only)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| QUO-E01 | Edit a DRAFT | Change a line price, Save | Persists | High | Not Started | |
| QUO-E02 | location_id is NOT part of the header key (documented gotcha) | Edit and re-save | No FK errors involving location_id on child tables | Med | Not Started | |

## View / Resume Draft
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| QUO-V01 | Reload matches saved state | Save, reopen | All fields match | High | Not Started | |

## List Screen
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| QUO-L01 | Filter by status/customer | Apply filters | Correct subset shows | Med | Not Started | |

## Print
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| QUO-P01 | Print shows Prospect party info correctly | Print a prospect quotation | `party_*` fields print correctly (never conditionally branching on customer_type) | Med | Not Started | |

## Approve
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| QUO-A01 | Button state after Approve (CCC #4) | Approve | Buttons disable correctly | High | Passed | `SQ/MAIN/2026/00001` approved — status APPROVED, `grand_total=500.00`, no GL/stock effect (pure pre-commitment document, confirmed by design). |
| QUO-A02 | Permission gating (CCC #6, `SL-QUO`) | Approve without the right | Denied | High | Not Started | |

## Convert-to-Sales Order
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| QUO-CV01 | Convert a Prospect quotation | Convert to Sales Order | `fn_convert_prospect_to_customer` creates a real `rim_accounts` row, quotation's `customer_id` updates, logged to `rih_prospect_conversions` | High | Not Started | |
| QUO-CV02 | Partial conversion | Convert only some lines' qty | Sales Order gets the converted qty, quotation tracks remaining correctly | Med | Not Started | |
| QUO-CV03 | Double-conversion | Attempt to convert an already-fully-converted quotation | Blocked or correctly shows zero remaining | Med | Not Started | |

## Cross-Screen Impact
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| QUO-XS01 | Sales Quotation Register | Approve/convert | Register + Quotation Conversion Analysis reflect it (`reports/sales_reports.md`) | High | Not Started | |
| QUO-XS02 | Open Sales Orders / downstream Invoice | Full conversion chain: Quotation → Order → Invoice | Every downstream document inherits correct frozen values, source doc status updates at each step | High | Passed | Full chain run E2E `2026-10-25`: `SQ/MAIN/2026/00001` → `SO/MAIN/2026/00001` (AGAINST_QUOTATION, rate frozen at 100.00, `source_quotation_no` set) → `SI/MAIN/2026/00001` (AGAINST_ORDER, Credit, same rate/qty inherited) → correctly posted GL (Dr Customer 500/Cr Sales 500) + COGS (Dr COS 125/Cr Stock 125) + stock dispatch (20→15). See `sales_order.md`/`sales_invoice.md` for each step's own detail. |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.
