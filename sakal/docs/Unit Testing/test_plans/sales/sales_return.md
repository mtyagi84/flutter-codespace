# Sales Return — Test Plan
Route: `/sales/returns` | Module: SL — Sales | Feature Code: SL-RET
See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
## Create
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SRET-C01 | Return against an approved Sales Invoice | Pick invoice, return some/all lines | Saves as DRAFT | High | Passed | E2E `2026-10-25`: picked `SI/MAIN/2026/00001` (5.00 invoiced), reduced the pre-filled Return Qty Pack from 5.00 to 2.00 (explicit click→retype, confirming the documented pre-fill-not-bound-to-form-state gotcha applies here too), saved as `SRET/MAIN/2026/00001` DRAFT correctly, Return Total 200.00. |
| SRET-C02 | Batch/serial-tracked return | Return a tracked product | Mandatory allocation from what was originally sold (CCC #10) | High | Not Started | |

## Edit / View
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SRET-E01 | Edit a DRAFT | Change qty, Save | Persists | High | Not Started | |
| SRET-V01 | Reload matches saved state | Save, reopen | Matches | High | Not Started | |

## List / Print
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SRET-L01 | Filter by status | Apply filter | Correct subset | Med | Not Started | |
| SRET-P01 | Print | Print an approved return | Renders correctly with signatures | Med | Not Started | |

## Approve
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SRET-A01 | Stock returns to inventory | Approve | `ril_stock_ledger`/`rim_product_location` reflect the inward movement | High | Passed | `SRET/MAIN/2026/00001` approved. DB-verified: `ril_stock_ledger` row `trans_type='SALES_RETURN', qty_change=+2`; `rim_product_location.current_stock` for PRD-00002 at Main Store moved 15→17. GL: `COS` voucher reversal Dr Stock Account 50/Cr Cost of Sales 50 (2×25 cost basis); `CRN` (Credit Note) voucher Dr Sales of Goods 200/Cr Customer 200 (2×100). **Real config gap found and fixed**: first Approve attempt failed with "No Sales Returns Account resolved for product..." — `SALES_RETURNS_ACCOUNT` link type was never configured on this fresh tenant (same class of gap as Stock Transfer's own `STOCK_IN_TRANSIT_ACCOUNT` gap found earlier this session). Configured live via Account Link Setup → Sales Returns Account → Company-wide → `[7010] Sales of Goods` (no dedicated contra-revenue leaf exists in this seeded OHADA COA — reusing the sales account is a reasonable choice for this smoke test). Not a code bug — a new-tenant-starter-kit gap, consistent with `STOCK_IN_TRANSIT_ACCOUNT` not being in the auto-wired set either. |
| SRET-A02 | Cash refund (if applicable) | Approve a cash-refund return | Composed CRV/CPV settlement voucher posts correctly, tagged with `source_doc_type='SALES_RETURN'` so it's exempt from the unrelated `FN-PRV` permission guard | High | Not Started | |
| SRET-A03 | Button state after Approve (CCC #4) | Approve | Buttons disable correctly | High | Not Started | |
| SRET-A04 | Permission gating (CCC #6, `SL-RET`) | Approve without the right | Denied | High | Not Started | |

## Cross-Screen Impact
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SRET-XS01 | Sales Return Register | Approve | Reflects it (`reports/sales_reports.md` RETR-01) | High | Not Started | |
| SRET-XS02 | Original invoice / customer ledger | Approve | Customer's balance reduces correctly, Account Ledger shows the reversal (CCC #1) | High | Not Started | |
| SRET-XS03 | Stock reports | Approve | Stock Ledger/Balance reflect the inward movement | High | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.
