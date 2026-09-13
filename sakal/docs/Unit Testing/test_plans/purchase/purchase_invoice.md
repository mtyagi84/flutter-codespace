# Purchase Invoice (Purchase Bill) — Test Plan
Route: `/purchase/invoices` | Module: PR — Purchase | Feature Code: PR-INV
Closes the GR/IR loop GRN opened (migration 054). See `00_INDEX.md` for the
Cross-Cutting Checklist ("CCC #N").

---
## Create
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PINV-C01 | Bill one GRN, same rate as GRN | Pick supplier, pick the GRN | Amounts pre-fill correctly | High | Not Started | |
| PINV-C02 | Bill one GRN, DIFFERENT rate than GRN (FX gap) | Change the bill's own rate | System will need a separate EXC voucher at approve time — see PINV-A02 | High | Not Started | |
| PINV-C03 | Bill multiple GRNs, same supplier+currency | Consolidate 2+ GRNs | All lines correct | Med | Not Started | |
| PINV-C04 | Real VAT entered from supplier's paper invoice | Type the actual VAT amount | Apportioned across linked GRN lines by their estimated-tax share | High | Not Started | |
| PINV-C05 | Whole-GRN billing only | Attempt to bill only part of a GRN's lines | Confirm this is correctly NOT possible (v1 scope: whole-GRN only) | Med | Not Started | |

## Edit / View
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PINV-E01 | Edit a DRAFT, change the date | Change date, Save | Old-date-first line deletion ordering doesn't break (a real bug class fixed once) | High | Not Started | |
| PINV-E02 | Immutability (CCC #5) | Approve, attempt edit | Blocked | High | Not Started | |
| PINV-V01 | Reload matches saved state | Save, reopen | Matches | High | Not Started | |

## List / Print
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PINV-L01 | Filter by status | Apply filter | Correct subset | Med | Not Started | |
| PINV-P01 | Print | Print an approved bill | Renders correctly | Med | Not Started | |

## Approve
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PINV-A01 | PUR voucher balances on its own | Approve a same-rate bill | Dr Purchase Accrual (exact GRN replay) + Dr Input VAT = Cr Supplier, balances exactly | High | Not Started | |
| PINV-A02 | Separate EXC voucher for an FX gap | Approve a different-rate bill | A SEPARATE `EXC` voucher posts the exchange gain/loss, both in base currency, no `inv_bill_no` on that leg | High | Not Started | |
| PINV-A03 | Supplier line usable in Pending Bills | Approve | `inv_bill_no`/`inv_bill_date` = the supplier's OWN invoice number/date, wires into Pending Bills correctly | High | Not Started | |
| PINV-A04 | Button state after Approve (CCC #4) | Approve | Buttons disable | High | Not Started | |
| PINV-A05 | Permission gating (CCC #6, `PR-INV`) | Approve without the right | Denied | High | Not Started | |

## Cross-Screen Impact
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PINV-XS01 | GRN Pending to Bill clears | Approve | GRN drops off Pending to Bill | High | Not Started | |
| PINV-XS02 | Purchase Invoice Register + Purchase Tax Summary | Approve | Both reflect it exactly (`reports/purchase_reports.md`) | High | Not Started | |
| PINV-XS03 | Payment Voucher can settle this bill | Go to Payment/Receipt Voucher, settle against this bill | Bill amount/reference resolves correctly (CCC #3 — cross-check against the known Party Amount bug) | High | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.
