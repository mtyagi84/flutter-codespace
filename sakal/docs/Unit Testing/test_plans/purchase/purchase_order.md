# Purchase Order — Test Plan
Route: `/purchase/orders` | Module: PR — Purchase | Feature Code: PR-PO
See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N"). Note: the seed
function once pointed this menu item at a dead `/purchase/order-entry` route —
fixed; confirm the List→Entry navigation still works correctly.

---
## Create
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PO-C01 | Create with a supplier + lines | Pick supplier, add lines, Save | Saves as DRAFT | High | Passed | E2E `test_purchase_order.js` 10/10: Supplier [4010001] QA Test Supplier, Product PRD-00001, Qty Pack 10 x Rate 50 USD = 500, Save Draft then Approve, DB-verified exactly. Confirmed no GL/stock posting occurs at PO Approve (pure intent, as documented) — correctly deferred to GRN. |
| PO-C02 | Landed cost estimate | Add a charge | Landed cost per line computed as an estimate (not final costing) | Med | Not Started | |
| PO-C03 | Batch/serial product line | Add a tracked product | Free-text new-lot entry available (batch/serial not mandatory at DRAFT for PO) | Med | Not Started | |
| PO-C04 | Barcode scan | Scan a barcode | Product resolves, `matchedBarcode` saved onto the line correctly (a past bug: it was cleared before save) | Med | Not Started | |
| PO-C05 (new) | Tax Group auto-defaults from the product's own Purchase Tax Group | Pick a product with a Purchase Tax Group configured (Product Master) | Line's Tax Group field auto-populates, no manual selection needed | Med | Passed | E2E `2026-11-01`: assigned `TVA Standard 16%` as `[PRD-00001]`'s Purchase Tax Group via Product Master, then created `PO/2026/00003` (10 PCS @ 100 USD) — the line's Tax Group auto-defaulted to "TVA Standard 16%" the moment the product was selected, correctly computing Item Tax=160.00 (16% of 1,000 Gross), Grand Total=1,160.00. This PO/GRN/Purchase-Invoice chain is what unblocked `purchase_invoice.md`'s own previously-deferred PINV-C04 (real VAT apportionment). |

## Edit / View
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PO-E01 | Edit a DRAFT | Change qty, Save | Persists | High | Not Started | |
| PO-E02 | Immutability (CCC #5) | Approve, attempt edit | Blocked | High | Not Started | |
| PO-V01 | Reload matches saved state | Save, reopen | Matches | High | Not Started | |

## List / Print
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PO-L01 | Filter by status | Apply filter | Correct subset | Med | Not Started | |
| PO-P01 | Print | Print an approved PO | Renders correctly | Med | Not Started | |

## Approve
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PO-A01 | Button state after Approve (CCC #4) | Approve | Buttons disable | High | Not Started | |
| PO-A02 | Permission gating (CCC #6, `PR-PO`) | Approve without the right | Denied | High | Not Started | |

## Cancel
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PO-X01 | Cancel a DRAFT | Cancel | No downstream effect | High | Not Started | |
| PO-X02 | Cancel a partially-received PO | Attempt cancel after one GRN | Verify actual supported behavior | Med | Not Started | |

## Cross-Screen Impact (Convert-to-GRN is the natural next step, tracked in grn.md)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PO-XS01 | PO Register + Pending POs | Approve, then fully receive via GRN | PO drops off Pending POs, appears fully in Register (`reports/purchase_reports.md`) | High | Not Started | |
| PO-XS02 | Rate inheritance on GRN | Approve PO with a specific rate, then receive via GRN Against-PO | GRN's rate defaults from the PO's own `rate_to_base`/`rate_to_local`, not a fresh lookup | High | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.
