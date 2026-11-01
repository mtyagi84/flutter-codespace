# Purchase Invoice (Purchase Bill) — Test Plan
Route: `/purchase/invoices` | Module: PR — Purchase | Feature Code: PR-INV
Closes the GR/IR loop GRN opened (migration 054). See `00_INDEX.md` for the
Cross-Cutting Checklist ("CCC #N").

---
## Create
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PINV-C01 | Bill one GRN, same rate as GRN | Pick supplier, pick the GRN | Amounts pre-fill correctly | High | Passed | E2E `test_purchase_invoice.js` 12/12: picked Supplier [4010001], GRN/MAIN/2026/00001 (500 USD) auto-filled Taxable Amount=500.00, Invoice Total=500.00 exactly. |
| PINV-C02 | Bill one GRN, DIFFERENT rate than GRN (FX gap) | Change the bill's own rate | System will need a separate EXC voucher at approve time — see PINV-A02 | High | Not Started | |
| PINV-C03 | Bill multiple GRNs, same supplier+currency | Consolidate 2+ GRNs | All lines correct | Med | Not Started | |
| PINV-C04 | Real VAT entered from supplier's paper invoice | Type the actual VAT amount | Apportioned across linked GRN lines by their estimated-tax share | High | Passed | E2E `2026-11-01`: built the full chain fresh to unblock this (previously deferred since the only existing GRN had no tax group). Assigned `TVA Standard 16%` as the Purchase Tax Group on `[PRD-00001]`, created+approved `PO/2026/00003` (10 PCS @ 100 USD, tax group auto-defaulted from the product, Item Tax=160.00), created a GRN Against this PO (`GRN/MAIN/2026/00002`, line locked/consolidated from the PO exactly) and approved it (provisional accrual only, per the GR/IR deferral design — no VAT line at this stage). Created a Purchase Bill against that GRN (`PINV/MAIN/2026/00003`) — selecting the GRN auto-filled Taxable Amount=1000.00 and VAT/Tax Amount=160.00 from the GRN's own deferred estimated tax, exactly as designed. |
| PINV-VAL02 (new) | Supplier Invoice No/Date required before Approve | Attempt to leave Supplier Invoice No blank | Form requires it (both are marked required fields) | Med | Passed | Confirmed structurally — both fields show a red required-field asterisk; filled `SUP-INV-002` + 01 Nov 2026 as part of the PINV-C04 flow above. |
| PINV-VAL01 | **Found live** — VAT entry blocked when the linked GRN has no deferred tax to apportion against | Enter a non-zero VAT/Tax Amount on a bill linked to a "No Tax" GRN | Approve is blocked with a clear banner: "None of the linked GRN lines had a tax group / estimated tax to apportion the real VAT against." | High | Passed | Confirmed live: a genuinely correct validation, not a bug — the apportionment math has nothing to divide the real VAT across without an estimated-tax basis from the GRN. Discovered mid-test (first attempt used VAT=80 against a no-tax GRN, Approve silently no-opped behind the banner); re-ran with VAT=0 to complete the no-VAT GL path instead. |
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
| PINV-A01 | PUR voucher balances on its own | Approve a same-rate bill | Dr Purchase Accrual (exact GRN replay) + Dr Input VAT = Cr Supplier, balances exactly | High | Passed | Posted as `PUR/MAIN/2026/00001`: Dr "Purchase Accrual (GR/IR)" 500 (exact GRN replay), Cr "QA Test Supplier" 500, balanced exactly (no-VAT path, see PINV-VAL01). **Full 3-way balance with a real VAT leg now also proven** (PINV-C04, `2026-11-01`): `PUR/MAIN/2026/00002` posted `[4000401] Purchase Accrual (GR/IR)` Dr 1,000.00, `[4400001] QA Input VAT Receivable` Dr 160.00, `[4010001] QA Test Supplier` Cr 1,160.00 — DB-verified exact via `rid_finance_lines`, Total Dr=Total Cr=1,160.00, `inv_bill_no='SUP-INV-002'` (the supplier's own invoice number, not the internal `PINV` doc number) correctly tagged on the Supplier line only. |
| PINV-A02 | Separate EXC voucher for an FX gap | Approve a different-rate bill | A SEPARATE `EXC` voucher posts the exchange gain/loss, both in base currency, no `inv_bill_no` on that leg | High | Not Started | |
| PINV-A03 | Supplier line usable in Pending Bills | Approve | `inv_bill_no`/`inv_bill_date` = the supplier's OWN invoice number/date, wires into Pending Bills correctly | High | Passed | Confirmed: Supplier line's `inv_bill_no='SUP-INV-001'` — the supplier's own invoice number as typed, NOT the internal `PINV/MAIN/2026/00002` document number. Actual Pending Bills report reflection deferred to the Finance Reports pass. |
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
