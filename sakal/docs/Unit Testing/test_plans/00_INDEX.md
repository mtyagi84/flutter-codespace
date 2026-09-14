# SAKAL Screen-by-Screen Test Plan — Master Index

**Last updated:** 2026-09-13
**How to use this document:** every screen in the app has one row below, linking to
its detail file. Update the **Status** column as you test. When you find a bug,
note it in **Open Bugs** with a one-line description and (once fixed) the fix
commit. Detail files hold the actual test cases (steps, expected result, pass/fail).

Status values: `Not Started` · `In Progress` · `Passed` · `Failed` · `Blocked` (a
prerequisite screen/master isn't ready) · `N/A — Not Built` (route is still a
placeholder, see below).

## Cross-Cutting Checklist — applies to EVERY screen, every detail file references this

This list exists because 4 real bugs were found (2026-09-13) that a shallow
"does it load / does it save" check would have missed entirely. Apply every item
below to every test case where it's relevant — don't treat these as a separate
one-time pass, they are how the ordinary test cases below need to be *written*:

1. **Dr/Cr, never a bare negative.** Any balance/amount that can be a debit or a
   credit must display with an explicit `Dr`/`Cr` label — never a signed negative
   number. *(Found live: Account Ledger — see `reports/finance_reports.md`.)*
2. **Currency shown wherever it can vary.** Any report/statement/line showing an
   amount in other-than-base currency must show the currency code/symbol.
   *(Found live: a party's ledger-currency statement — see `reports/finance_reports.md`.)*
3. **Reactive fields actually react.** Any field meant to auto-populate from a
   sibling field must do so the instant the sibling changes — check this
   immediately, don't just check that Save works afterward. *(Found live: Payment
   Voucher On Account line's Party Amount — see `finance/payment_receipt_voucher.md`.)*
4. **Button state after the action, in the same test case.** Every Save
   Draft/Approve/Post/Cancel button's enabled/disabled/visible state must be
   explicitly asserted right after that same action — never assumed. *(Found live:
   Sales Delivery buttons stay enabled after Approve — see `sales/sales_delivery.md`.)*
5. **Immutability.** Once APPROVED/POSTED, attempting to edit must be blocked.
6. **Permission gating.** The action is denied for a user lacking the relevant
   `ric_user_menus` right for that `feature_code`.
7. **Responsive.** Works at a narrow (~400px) width with no overflow.
8. **Offline**, if the screen supports it — data queues and syncs correctly.
9. **Pack/Loose Qty + Barcode gating**, if the screen has product/item lines —
   respects `ric_companies.qty_entry_mode` / `enable_barcode`.
10. **Batch/Serial handling**, if the screen's products can be tracked — correct
    UI shape (new-lot entry vs. existing-lot picker) for the document type.

---

## AD — Settings (47 screens)

### System Setup (13) — detail file: [`masters/system_setup.md`](masters/system_setup.md)
| Screen | Feature Code | Route | Status | Open Bugs |
|---|---|---|---|---|
| Company Setup | AD-CMP | /setup/company | Passed (backend, indirect) | Singleton per-company config, implicitly exercised by every test file in this suite (all log in against an already-configured real QA company) |
| Location Setup | AD-LOC | /setup/locations | Passed (backend, indirect) | ric_locations CRUD exercised directly in user_management_backend_test.dart (AD-ULS test creates a real location) |
| Currency Setup | AD-CUR | /setup/currencies | Passed (backend) | |
| Period Close | AD-PDC | /setup/period-close | Passed (backend) | |
| Backdated Entry Control | AD-BDC | /setup/backdated-entry-control | Passed (backend) | |
| Quick Invoice Setup | AD-QIS | /setup/quick-invoice-setup | Passed (backend, indirect) | Exercised directly by CommonRefs.ensureQuickInvoiceSetup() as Cash Receipt/Sales Invoice fixture setup |
| Country Setup | AD-CNT | /setup/countries | Passed (backend) | |
| Country Divisions | AD-DIV | /setup/divisions | N/A (global lookup) | rim_divisions is a GLOBAL table (is_system=true OR client+company) per its own documented design, not company-specific CRUD |
| Cities | AD-CIT | /setup/cities | Passed (backend) | |
| Print Templates | AD-PDT | /setup/print-templates | Passed (backend) | |
| Accounting Setup | AD-ACT | /setup/accounting | Passed (backend, indirect) | Singleton per-company config, same reasoning as Company Setup |
| Common Masters | MST-CMN | /master/common-masters | Passed (backend) | |
| Payment Terms | AD-PAYTERM | /master/payment-terms | Passed (backend) | |

### User Management (4) — detail file: [`masters/user_management.md`](masters/user_management.md)
| Screen | Feature Code | Route | Status | Open Bugs |
|---|---|---|---|---|
| User Management | AD-USR | /setup/users | Passed (backend) | Has a dedicated fn_create_user RPC (server-side crypt() password hashing), unlike plain-CRUD masters |
| User Permissions | AD-PRM | /setup/permissions | Passed (backend) | |
| User Location Setup | AD-ULS | /setup/user-location-access | Passed (backend) | |
| Master Menu | AD-MST | /setup/master-menu | Passed (backend) | |

### Sales Masters (3) — detail file: [`masters/sales_masters.md`](masters/sales_masters.md)
| Screen | Feature Code | Route | Status | Open Bugs |
|---|---|---|---|---|
| Customer Master | MST-CUST | /master/customers | Passed (backend) | |
| Price Master | SL-PRC | /sales/price-master | Passed (backend) | Has a real Draft/Approve lifecycle (fn_save_price_master_batch/fn_approve_price_master_batch), unlike every other Master screen — closer in shape to a transaction screen |
| Sales Executives | SL-EXE | /sales/sales-executives | Passed (backend) | |

### Purchase Masters (1) — detail file: [`masters/purchase_masters.md`](masters/purchase_masters.md)
| Screen | Feature Code | Route | Status | Open Bugs |
|---|---|---|---|---|
| Supplier Master | MST-SUPP | /master/suppliers | Passed (backend) | |

### Inventory Masters (5) — detail file: [`masters/inventory_masters.md`](masters/inventory_masters.md)
| Screen | Feature Code | Route | Status | Open Bugs |
|---|---|---|---|---|
| Product Master | MST-PRD | /master/products | Passed (backend) | |
| Item Categories | MST-ITC | /master/item-categories | Passed (backend) | |
| Product Category Level Setup | AD-PCS | /setup/category-levels | Passed (backend) | |
| Product Flag Types | AD-PGS | /setup/product-flag-types | Passed (backend) | |
| Consumption Area Setup | IN-DCA | /inventory/department-consumption-areas | Passed (backend, indirect) | Exercised repeatedly via CommonRefs.loadOrCreateDepartmentArea() against the real rim_department_consumption_areas table |

### Finance Masters (8) — detail file: [`masters/finance_masters.md`](masters/finance_masters.md)
| Screen | Feature Code | Route | Status | Open Bugs |
|---|---|---|---|---|
| Chart of Accounts | MST-COA | /master/accounts | Passed (backend) | Covered via masters_crud_backend_test.dart (same rim_accounts table as Customer/Supplier) |
| Tax Master | MST-TAX | /master/tax-master | Passed (backend) | |
| Tax Groups | MST-TXG | /master/tax-groups | Passed (backend) | |
| Account Link Setup | MST-ALS | /master/account-link-setup | Passed (backend, indirect) | Exercised repeatedly all session via CommonRefs ensure*AccountLink() helpers against the real rim_account_link_setup/rim_account_link_defaults tables |
| Item Account Links | MST-IAL | /master/item-account-links | Passed (backend) | |
| Additional Charges | MST-CHG | /master/additional-charges | Passed (backend) | |
| Exchange Rates | FN-EX | /finance/exchange-rates | Passed (backend) | mid_rate renamed to exchange_rate (migration 179) — not a bare-computed column anymore |
| Opening Balance | MST-OB | /master/opening-balances | Passed (backend) | Real table is rid_opening_balance_lines (migration 133) — rim_opening_balances (migration 013) is dead/orphaned schema, never consumed by the screen |

### Master Reports (13) — detail file: [`reports/master_data_reports.md`](reports/master_data_reports.md)
| Screen | Feature Code | Route | Status | Open Bugs |
|---|---|---|---|---|
| Item/Product Master Report | MST-RPT-PRD | /reports/PRODUCT_MASTER_REPORT | Passed (backend, smoke) | |
| Customer Master Report | MST-RPT-CUS | /reports/CUSTOMER_MASTER_REPORT | Passed (backend, smoke) | |
| Supplier Master Report | MST-RPT-SUP | /reports/SUPPLIER_MASTER_REPORT | Passed (backend, smoke) | |
| Chart of Accounts Report | MST-RPT-COA | /reports/CHART_OF_ACCOUNTS_REPORT | Passed (backend, smoke) | |
| Chart of Groups Report | MST-RPT-GRP | /reports/CHART_OF_GROUPS_REPORT | Passed (backend, smoke) | |
| Item Category Master Report | MST-RPT-ITC | /reports/ITEM_CATEGORY_MASTER_REPORT | Passed (backend, smoke) | |
| Common Masters Report | MST-RPT-CMN | /reports/COMMON_MASTERS_REPORT | Passed (backend, smoke) | |
| Tax Master Report | MST-RPT-TAX | /reports/TAX_MASTER_REPORT | Passed (backend, smoke) | |
| Tax Group Master Report | MST-RPT-TXG | /reports/TAX_GROUP_MASTER_REPORT | Passed (backend, smoke) | |
| Payment Terms Master Report | MST-RPT-PYT | /reports/PAYMENT_TERMS_MASTER_REPORT | Passed (backend, smoke) | |
| Sales Executives Master Report | MST-RPT-SEX | /reports/SALES_EXECUTIVES_MASTER_REPORT | Passed (backend, smoke) | |
| Additional Charges Master Report | MST-RPT-CHG | /reports/ADDITIONAL_CHARGES_MASTER_REPORT | Passed (backend, smoke) | |
| Price List Report | MST-RPT-PRC | /reports/PRICE_LIST_REPORT | Passed (backend, smoke) | |

---

## SL — Sales (21 screens)

### Transactions (8) — each has its own detail file in [`sales/`](sales/)
| Screen | Feature Code | Route | Detail File | Status | Open Bugs |
|---|---|---|---|---|---|
| Sales Quotation | SL-QUO | /sales/quotations | [sales_quotation.md](sales/sales_quotation.md) | Passed (backend) | Create/Approve/no-stock-effect/immutability verified via `test/backend/sales_quotation_backend_test.dart`, 2026-09-14. CCC #4/#7 not yet UI-verified. |
| Sales Order | SL-SO | /sales/orders | [sales_order.md](sales/sales_order.md) | Passed (backend) | DIRECT mode + manual price override/Approve/Cancel-requires-reason verified via `test/backend/sales_order_backend_test.dart`, 2026-09-14. CCC #4/#7 not yet UI-verified. |
| Sales Invoice | SL-INV | /sales/invoices | [sales_invoice.md](sales/sales_invoice.md) | Passed (backend) | DIRECT/CREDIT sale, Approve, stock dispatch + SI/COS GL posting, cancel-blocked-once-approved verified via `test/backend/sales_invoice_backend_test.dart`, 2026-09-14. CCC #4/#7 not yet UI-verified. |
| Pending Approvals | SL-INR | /sales/pending-approvals | [pending_approvals.md](sales/pending_approvals.md) | N/A (backend) | Pure aggregation/list view, no own fn_save/fn_approve — underlying approve logic already covered by each source screen's own test. Needs UI-only verification (does it correctly list DRAFT docs across modules). |
| Sales Return | SL-RET | /sales/returns | [sales_return.md](sales/sales_return.md) | Passed (backend) | Return against an APPROVED invoice, stock genuinely comes back verified via `test/backend/sales_return_backend_test.dart`, 2026-09-14. Found+fixed missing SALES_RETURNS_ACCOUNT link. CCC #4/#7 not yet UI-verified. |
| Sales Delivery | SL-DEL | /sales/deliveries | [sales_delivery.md](sales/sales_delivery.md) | Passed (backend) | Buttons-stay-enabled bug fixed `a172574` (UI-only). Backend logic (deferred-dispatch Credit Invoice → Delivery → stock leaves only at delivery, not invoice) verified via `test/backend/sales_delivery_backend_test.dart`, 2026-09-14. CCC #4 button-state itself still needs UI verification. |
| Cash Receipt | SL-RCP | /sales/receipts | [cash_receipt.md](sales/cash_receipt.md) | Passed (backend) | Settle a real pending bill from a Credit Sales Invoice verified via `test/backend/cash_receipt_backend_test.dart`, 2026-09-14. Found+fixed FOUR real QA-tenant fixture gaps (approve permission, Quick Invoice Setup, Exchange Gain/Loss link — see AUTOMATED_RUN_LOG.md). CCC #4/#7 not yet UI-verified. |
| Credit Sales Invoice | SL-CINV | /sales/credit-invoices | [credit_sales_invoice.md](sales/credit_sales_invoice.md) | Passed (backend) | Hard future-date block + date-locked-after-first-save (both migration 146's own distinguishing rules) verified via `test/backend/credit_sales_invoice_backend_test.dart`, 2026-09-14. CCC #4/#7 not yet UI-verified. |

### Reports (13) — detail file: [`reports/sales_reports.md`](reports/sales_reports.md)
| Screen | Feature Code | Route | Status | Open Bugs |
|---|---|---|---|---|
| Sales Register | SL-RPT-REG | /reports/SALES_REGISTER | Passed (backend, smoke) | |
| Item-wise Gross Profit | SL-RPT-IGP | /reports/ITEM_GROSS_PROFIT | Passed (backend, smoke) | |
| Invoice-wise Gross Profit | SL-RPT-VGP | /reports/INVOICE_GROSS_PROFIT | Passed (backend, smoke) | |
| Customer-wise Gross Profit | SL-RPT-CGP | /reports/CUSTOMER_GROSS_PROFIT | Passed (backend, smoke) | |
| Salesperson-wise Performance | SL-RPT-SPP | /reports/SALESPERSON_PERFORMANCE | Passed (backend, smoke) | |
| Sales Return Register | SL-RPT-RET | /reports/SALES_RETURN_REGISTER | Passed (backend, smoke) | |
| Sales Quotation Register | SL-RPT-SQR | /reports/SALES_QUOTATION_REGISTER | Passed (backend, smoke) | |
| Sales Order Register | SL-RPT-SOR | /reports/SALES_ORDER_REGISTER | Passed (backend, smoke) | |
| Quotation Conversion Analysis | SL-RPT-QCA | /reports/QUOTATION_CONVERSION_ANALYSIS | Passed (backend, smoke) | |
| Open Sales Orders | SL-RPT-OSO | /reports/OPEN_SALES_ORDERS | Passed (backend, smoke) | |
| Sales Delivery Register | SL-RPT-SDR | /reports/SALES_DELIVERY_REGISTER | Passed (backend, smoke) | |
| Pending Deliveries | SL-RPT-PDL | /reports/PENDING_DELIVERIES | Passed (backend, smoke) | |
| Cash Receipt / Collections Register | SL-RPT-CRR | /reports/CASH_RECEIPT_REGISTER | Passed (backend, smoke) | |

---

## PR — Purchase (18 screens)

### Transactions (5) — each has its own detail file in [`purchase/`](purchase/)
| Screen | Feature Code | Route | Detail File | Status | Open Bugs |
|---|---|---|---|---|---|
| Purchase Order | PR-PO | /purchase/orders | [purchase_order.md](purchase/purchase_order.md) | Passed (backend) | Create/Approve/immutability/PO_NO_LINES verified via `test/backend/purchase_order_backend_test.dart`, 2026-09-14. CCC #4/#7 not yet UI-verified. |
| Goods Receipt (GRN) | PR-GRN | /purchase/grn | [grn.md](purchase/grn.md) | Passed (backend) | Create/Approve/stock-cost/immutability verified via `test/backend/grn_backend_test.dart`, 2026-09-14. CCC #4/#7 (button state, responsive) not yet UI-verified — see `AUTOMATED_RUN_LOG.md`. |
| Purchase Invoice | PR-INV | /purchase/invoices | [purchase_invoice.md](purchase/purchase_invoice.md) | Passed (backend) | Bill-a-GRN/Approve/GR-IR clearing/pending-bills-linkage/double-claim-block/immutability verified via `test/backend/purchase_invoice_backend_test.dart`, 2026-09-14. CCC #4/#7 not yet UI-verified. |
| Purchase Return | PR-RET | /purchase/returns | [purchase_return.md](purchase/purchase_return.md) | Passed (backend) | Partial return (30/100) against unbilled GRN → stock rolls back correctly → immutability blocked. Verified via `test/backend/purchase_return_backend_test.dart`, 2026-09-14. Billed/SDN branch not yet covered. CCC #4/#7 not yet UI-verified. |
| Supplier Payment | PR-PAY | /purchase/payments | — | **N/A — Not Built** | Route is still a placeholder |

### Reports (13) — detail file: [`reports/purchase_reports.md`](reports/purchase_reports.md)
| Screen | Feature Code | Route | Status | Open Bugs |
|---|---|---|---|---|
| Purchase Order Register | PR-RPT-POR | /reports/PURCHASE_ORDER_REGISTER | Passed (backend, smoke) | |
| Pending Purchase Orders | PR-RPT-PPO | /reports/PENDING_PURCHASE_ORDERS | Passed (backend, smoke) | |
| GRN Register | PR-RPT-GRN | /reports/GRN_REGISTER | Passed (backend, smoke) | |
| GRN Pending to Bill | PR-RPT-GPB | /reports/GRN_PENDING_TO_BILL | Passed (backend, smoke) | |
| Purchase Invoice Register | PR-RPT-PIR | /reports/PURCHASE_INVOICE_REGISTER | Passed (backend, smoke) | |
| Purchase Return Register | PR-RPT-PRR | /reports/PURCHASE_RETURN_REGISTER | Passed (backend, smoke) | |
| Purchase Charges Register | PR-RPT-CHG | /reports/PURCHASE_CHARGES_REGISTER | Passed (backend, smoke) | |
| Supplier-wise Purchase Analysis | PR-RPT-SUP | /reports/SUPPLIER_PURCHASE_ANALYSIS | Passed (backend, smoke) | |
| Item-wise Purchase History | PR-RPT-ITM | /reports/ITEM_PURCHASE_HISTORY | Passed (backend, smoke) | |
| Reorder / Replenishment | PR-RPT-ROR | /reports/REORDER_REPLENISHMENT | Passed (backend, smoke) | |
| Vendor On-Time Delivery | PR-RPT-OTD | /reports/VENDOR_ON_TIME_DELIVERY | Failed (backend, smoke) | param_target mismatch (expected_date vs expected_delivery_date) — fix written, migration 186 not yet deployed
| Purchase Price Variance | PR-RPT-PPV | /reports/PURCHASE_PRICE_VARIANCE | Passed (backend, smoke) | |
| Purchase Tax Summary | PR-RPT-TAX | /reports/PURCHASE_TAX_SUMMARY | Passed (backend, smoke) | |

---

## IN — Inventory (25 screens)

### Transactions (10) — each has its own detail file in [`inventory/`](inventory/)
| Screen | Feature Code | Route | Detail File | Status | Open Bugs |
|---|---|---|---|---|---|
| Stock List | IN-STK | /inventory/stock | — | **N/A — Not Built** | Route is still a placeholder |
| Stock Transfer | IN-TRF | /inventory/transfers | [stock_transfer.md](inventory/stock_transfer.md) | Passed (backend) | DIRECT/SAME_BOOK mode: create/Approve/stock leaves FROM/immutability verified via `test/backend/stock_transfer_backend_test.dart`, 2026-09-14. Found+fixed missing STOCK_IN_TRANSIT_ACCOUNT link (QA tenant fixture gap). AGAINST_REQUEST + INTER_ENTITY modes not yet covered. CCC #4/#7 not yet UI-verified. |
| Stock Adjustment | IN-ADJ | /inventory/adjustments | [stock_adjustment.md](inventory/stock_adjustment.md) | Passed (backend) | Decrease ('-') line/Approve/stock decrease/immutability verified via `test/backend/stock_adjustment_backend_test.dart`, 2026-09-14. Found+fixed missing STOCK_ADJUSTMENT_ACCOUNT link (QA tenant fixture gap). Increase ('+') line + its COST_NOT_ESTABLISHED block not yet covered. CCC #4/#7 not yet UI-verified. |
| Material Requisition | IN-MRQ | /inventory/requisitions | [material_requisition.md](inventory/material_requisition.md) | Passed (backend) | Create/Approve/immutability verified, plus LINE_DEPARTMENT_AREA_REQUIRED correctly rejects a line with no department/area. Verified via `test/backend/material_requisition_backend_test.dart`, 2026-09-14. CCC #4/#7 not yet UI-verified. |
| Material Issue | IN-MIS | /inventory/material-issue | [material_issue.md](inventory/material_issue.md) | Passed (backend) | Consolidate-from-requisition/Approve/stock decrease/Dr-Expense-Cr-Stock GL posting verified via `test/backend/material_issue_backend_test.dart`, 2026-09-14. Found+fixed a real QA-tenant fixture gap (see AUTOMATED_RUN_LOG.md). CCC #4/#7 not yet UI-verified. |
| Stock Transfer Request | IN-STR | /inventory/stock-transfer-requests | [stock_transfer_request.md](inventory/stock_transfer_request.md) | Passed (backend) | Create/Approve/immutability verified via `test/backend/stock_transfer_request_backend_test.dart`, 2026-09-14. CCC #4/#7 not yet UI-verified. |
| Stock Receipt | IN-SRC | /inventory/stock-receipts | [stock_receipt.md](inventory/stock_receipt.md) | Passed (backend) | Completes a Stock Transfer — stock arrives correctly at TO location. Verified via `test/backend/stock_receipt_backend_test.dart`, 2026-09-14. CCC #4/#7 not yet UI-verified. |
| Opening Stock | IN-OPN | /inventory/opening-stock | [opening_stock.md](inventory/opening_stock.md) | Passed (backend) | Establish/Approve/OPENING_STOCK_ALREADY_ESTABLISHED-on-duplicate/immutability verified via `test/backend/opening_stock_backend_test.dart`, 2026-09-14. CCC #4/#7 not yet UI-verified. |
| Stock Count | IN-CNT | /inventory/stock-count | [stock_count.md](inventory/stock_count.md) | Passed (backend) | Blind count DRAFT→SUBMITTED lifecycle verified, plus confirms a count alone never moves stock. Via `test/backend/stock_count_backend_test.dart`, 2026-09-14. CCC #4/#7 not yet UI-verified. |
| Stock Count Review | IN-CNR | /inventory/stock-count-review | [stock_count_review.md](inventory/stock_count_review.md) | Passed (backend) | Approve correctly composes the Stock Adjustment engine — a real 5-unit shortage (50 system vs 45 counted) posts an auto-adjustment traced back via source_doc_type='STOCK_COUNT_REVIEW'. Via `test/backend/stock_count_review_backend_test.dart`, 2026-09-14. CCC #4/#7 not yet UI-verified. |

### Reports (15) — detail file: [`reports/inventory_reports.md`](reports/inventory_reports.md)
| Screen | Feature Code | Route | Status | Open Bugs |
|---|---|---|---|---|
| Stock Balance by Location | IN-RPT-SBM | /reports/STOCK_BALANCE_MATRIX | Passed (backend, smoke) | |
| Stock Value by Location | IN-RPT-SVL | /reports/STOCK_VALUE_BY_LOCATION | Passed (backend, smoke) | |
| Stock Details | IN-RPT-SDT | /reports/STOCK_DETAILS | Passed (backend, smoke) | |
| Stock Ledger | IN-RPT-SDL | /reports/STOCK_LEDGER | Passed (backend, smoke) | |
| Stock Transfer Register | IN-RPT-STR | /reports/STOCK_TRANSFER_REGISTER | Passed (backend, smoke) | |
| Pending Transfer to Receive | IN-RPT-STP | /reports/STOCK_TRANSFER_PENDING_RECEIPT | Passed (backend, smoke) | |
| Stock Receipt Register | IN-RPT-SRR | /reports/STOCK_RECEIPT_REGISTER | Passed (backend, smoke) | |
| Stock Adjustment Register | IN-RPT-SAD | /reports/STOCK_ADJUSTMENT_REGISTER | Passed (backend, smoke) | |
| Stock Adjustment Register (with Value) | IN-RPT-SAV | /reports/STOCK_ADJUSTMENT_REGISTER_VALUE | Passed (backend, smoke) | |
| Material Requisition Register | IN-RPT-MRQ | /reports/MATERIAL_REQUISITION_REGISTER | Passed (backend, smoke) | |
| Material Issue Register | IN-RPT-MIS | /reports/MATERIAL_ISSUE_REGISTER | Passed (backend, smoke) | |
| Stock Count Worksheet Register | IN-RPT-SCW | /reports/STOCK_COUNT_WORKSHEET_REGISTER | Passed (backend, smoke) | |
| Stock Count Variance Report | IN-RPT-SCV | /reports/STOCK_COUNT_VARIANCE_REPORT | Passed (backend, smoke) | |
| Stock Count Variance Report (with Value) | IN-RPT-SCV-V | /reports/STOCK_COUNT_VARIANCE_REPORT_VALUE | Passed (backend, smoke) | |
| Product Movement Analysis | IN-RPT-PMA | /reports/PRODUCT_MOVEMENT_ANALYSIS | Failed (backend, smoke) | RLS/GRANT regression from migration 185 — fix written, migration 186 not yet deployed

---

## FN — Finance (30 screens)

### Transactions (5) — each has its own detail file in [`finance/`](finance/)
| Screen | Feature Code | Route | Detail File | Status | Open Bugs |
|---|---|---|---|---|---|
| Journal Entry | FN-JRN | /finance/journal | [journal_entry.md](finance/journal_entry.md) | Passed (backend) | Balanced Dr/Cr entry posts + unbalanced entry rejected + immutability verified via `test/backend/journal_voucher_backend_test.dart`, 2026-09-14 — doubles as a smoke test of the shared voucher engine. CCC #4/#7 not yet UI-verified. |
| Contra Voucher | FN-CTR | /finance/contra | [contra_voucher.md](finance/contra_voucher.md) | Passed (backend) | Confirms CLAUDE.md's claim that Contra reuses the generic engine unchanged, under voucher_type_code='CTR'. Via `test/backend/contra_voucher_backend_test.dart`, 2026-09-14. CCC #4/#7 not yet UI-verified. |
| Expense Voucher | FN-EXP | /finance/expense-vouchers | [expense_voucher.md](finance/expense_voucher.md) | Passed (backend) | No-tax service bill/Approve/mandatory bill-linkage/immutability verified via `test/backend/expense_voucher_backend_test.dart`, 2026-09-14. Automatic-tax-expansion scenario not yet covered — follow-up. CCC #4/#7 not yet UI-verified. |
| Cash Book | FN-CBK | /finance/cashbook | — | **N/A — Not Built** | Route is still a placeholder |
| Payment/Receipt Voucher | FN-PRV | /finance/voucher-list | [payment_receipt_voucher.md](finance/payment_receipt_voucher.md) | Passed (backend) | Party-Amount bug fixed `a172574` (UI-only). On Account payment's party_amount confirmed round-tripping correctly via `test/backend/payment_receipt_voucher_backend_test.dart`, 2026-09-14. **Real cross-module inconsistency found** (not fixed): Against-Bill settlement's inv_bill_no matching convention differs between Sales Invoice/Cash Receipt (uses the posting voucher's own trans_no) and Expense Voucher/Purchase Bill (uses the user's own paper bill number) — see that test file's own doc comment. CCC #4/#7 not yet UI-verified. |

### Reports incl. Bank Reconciliation (21 + 4 = 25) — detail file: [`reports/finance_reports.md`](reports/finance_reports.md)
| Screen | Feature Code | Route | Status | Open Bugs |
|---|---|---|---|---|
| Trial Balance | FN-TRB | /reports/TRIAL_BALANCE | Passed (backend, smoke) | |
| Profit & Loss | FN-PNL | /reports/PROFIT_LOSS_SUMMARY | Passed (backend, smoke) | |
| Balance Sheet | FN-BSH | /reports/BALANCE_SHEET_SUMMARY | Passed (backend, smoke) | |
| Pending Bills Register | FN-RPT-PBR | /reports/PENDING_BILLS_REGISTER | Passed (backend, smoke) | |
| Pending Bills by Customer | FN-RPT-PBG | /reports/PENDING_BILLS_BY_CUSTOMER | Passed (backend, smoke) | |
| **Account Ledger** | FN-RPT-LDG | /reports/ACCOUNT_LEDGER | Passed (backend, smoke) | Dr/Cr + currency bugs fixed migration 184 (`a172574`), verified live vs. real data, pending redeploy verification. Underlying fn_account_ledger call itself confirmed reachable via reports_smoke_backend_test.dart, 2026-09-14. |
| Customer Ageing | FN-RPT-CAG | /reports/CUSTOMER_AGEING | Passed (backend, smoke) | |
| Supplier Ageing | FN-RPT-SAG | /reports/SUPPLIER_AGEING | Passed (backend, smoke) | |
| Pending Bills by Supplier | FN-RPT-PBS | /reports/PENDING_BILLS_BY_SUPPLIER | Passed (backend, smoke) | |
| Expense Report | FN-RPT-EXR | /reports/EXPENSE_REPORT_MATRIX | Passed (backend, smoke) | |
| Profit & Loss Account Detail | FN-RPT-PNL | /reports/PROFIT_LOSS_DETAIL | Passed (backend, smoke) | |
| Balance Sheet Account Detail | FN-RPT-BSD | /reports/BALANCE_SHEET_DETAIL | Passed (backend, smoke) | |
| Cash Flow Summary | FN-RPT-CFS | /reports/CASH_FLOW_SUMMARY | Passed (backend, smoke) | |
| Cash Flow Account Detail | FN-RPT-CFD | /reports/CASH_FLOW_DETAIL | Passed (backend, smoke) | |
| Day Book / Voucher Register | FN-RPT-DBK | /reports/DAY_BOOK_REGISTER | Failed (backend, smoke) | param_target mismatch (date vs trans_date) — fix written, migration 186 not yet deployed
| Cheque Register | FN-RPT-CHQ | /reports/CHEQUE_REGISTER | Failed (backend, smoke) | param_target mismatch (date vs trans_date) — fix written, migration 186 not yet deployed
| VAT / Tax Return Summary | FN-RPT-VAT | /reports/VAT_TAX_RETURN_SUMMARY | Failed (backend, smoke) | param_target mismatch (date vs trans_date) — fix written, migration 186 not yet deployed
| Withholding Tax Summary | FN-RPT-WHT | /reports/WITHHOLDING_TAX_SUMMARY | Failed (backend, smoke) | param_target mismatch (date vs trans_date) — fix written, migration 186 not yet deployed
| Financial Ratio Analysis | FN-RPT-RAT | /reports/FINANCIAL_RATIO_ANALYSIS | Passed (backend, smoke) | |
| Cash & Bank Position Summary | FN-RPT-CBP | /reports/CASH_BANK_POSITION_SUMMARY | Passed (backend, smoke) | |
| Bank Reconciliation Statement | FN-RPT-BRS | /reports/BANK_RECONCILIATION_STATEMENT | Passed (backend, smoke) | |

### Bank Reconciliation (4) — detail file: [`finance/bank_reconciliation.md`](finance/bank_reconciliation.md)
| Screen | Feature Code | Route | Status | Open Bugs |
|---|---|---|---|---|
| Bank Statement Format Master | FN-BSF | /finance/bank-statement-formats | Not Started | |
| Bank Accounts | FN-BAC | /finance/bank-accounts | Not Started | |
| Bank Statement Upload & Review | FN-BST | /finance/bank-statements | Not Started | |
| Bank Reconciliation Matching | FN-BRM | /finance/bank-reconciliation | Not Started | |

---

## Summary counts
- **Total real screens: 141** (+ 3 not-yet-built = 144 rows above)
- AD 47 · SL 21 · PR 18 · IN 25 · FN 30
- Transactions with dedicated per-screen files: 28 (SL 8, PR 5 incl. 1 not-built, IN 10 incl. 1 not-built, FN 5 incl. 1 not-built)
- Master/Setup screens (grouped): 34 across 6 files
- Reports (grouped): 79 across 5 files
