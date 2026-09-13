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
| Company Setup | AD-CMP | /setup/company | Not Started | |
| Location Setup | AD-LOC | /setup/locations | Not Started | |
| Currency Setup | AD-CUR | /setup/currencies | Not Started | |
| Period Close | AD-PDC | /setup/period-close | Not Started | |
| Backdated Entry Control | AD-BDC | /setup/backdated-entry-control | Not Started | |
| Quick Invoice Setup | AD-QIS | /setup/quick-invoice-setup | Not Started | |
| Country Setup | AD-CNT | /setup/countries | Not Started | |
| Country Divisions | AD-DIV | /setup/divisions | Not Started | |
| Cities | AD-CIT | /setup/cities | Not Started | |
| Print Templates | AD-PDT | /setup/print-templates | Not Started | |
| Accounting Setup | AD-ACT | /setup/accounting | Not Started | |
| Common Masters | MST-CMN | /master/common-masters | Not Started | |
| Payment Terms | AD-PAYTERM | /master/payment-terms | Not Started | |

### User Management (4) — detail file: [`masters/user_management.md`](masters/user_management.md)
| Screen | Feature Code | Route | Status | Open Bugs |
|---|---|---|---|---|
| User Management | AD-USR | /setup/users | Not Started | |
| User Permissions | AD-PRM | /setup/permissions | Not Started | |
| User Location Setup | AD-ULS | /setup/user-location-access | Not Started | |
| Master Menu | AD-MST | /setup/master-menu | Not Started | |

### Sales Masters (3) — detail file: [`masters/sales_masters.md`](masters/sales_masters.md)
| Screen | Feature Code | Route | Status | Open Bugs |
|---|---|---|---|---|
| Customer Master | MST-CUST | /master/customers | Not Started | |
| Price Master | SL-PRC | /sales/price-master | Not Started | |
| Sales Executives | SL-EXE | /sales/sales-executives | Not Started | |

### Purchase Masters (1) — detail file: [`masters/purchase_masters.md`](masters/purchase_masters.md)
| Screen | Feature Code | Route | Status | Open Bugs |
|---|---|---|---|---|
| Supplier Master | MST-SUPP | /master/suppliers | Not Started | |

### Inventory Masters (5) — detail file: [`masters/inventory_masters.md`](masters/inventory_masters.md)
| Screen | Feature Code | Route | Status | Open Bugs |
|---|---|---|---|---|
| Product Master | MST-PRD | /master/products | Not Started | |
| Item Categories | MST-ITC | /master/item-categories | Not Started | |
| Product Category Level Setup | AD-PCS | /setup/category-levels | Not Started | |
| Product Flag Types | AD-PGS | /setup/product-flag-types | Not Started | |
| Consumption Area Setup | IN-DCA | /inventory/department-consumption-areas | Not Started | |

### Finance Masters (8) — detail file: [`masters/finance_masters.md`](masters/finance_masters.md)
| Screen | Feature Code | Route | Status | Open Bugs |
|---|---|---|---|---|
| Chart of Accounts | MST-COA | /master/accounts | Not Started | |
| Tax Master | MST-TAX | /master/tax-master | Not Started | |
| Tax Groups | MST-TXG | /master/tax-groups | Not Started | |
| Account Link Setup | MST-ALS | /master/account-link-setup | Not Started | |
| Item Account Links | MST-IAL | /master/item-account-links | Not Started | |
| Additional Charges | MST-CHG | /master/additional-charges | Not Started | |
| Exchange Rates | FN-EX | /finance/exchange-rates | Not Started | |
| Opening Balance | MST-OB | /master/opening-balances | Not Started | |

### Master Reports (13) — detail file: [`reports/master_data_reports.md`](reports/master_data_reports.md)
| Screen | Feature Code | Route | Status | Open Bugs |
|---|---|---|---|---|
| Item/Product Master Report | MST-RPT-PRD | /reports/PRODUCT_MASTER_REPORT | Not Started | |
| Customer Master Report | MST-RPT-CUS | /reports/CUSTOMER_MASTER_REPORT | Not Started | |
| Supplier Master Report | MST-RPT-SUP | /reports/SUPPLIER_MASTER_REPORT | Not Started | |
| Chart of Accounts Report | MST-RPT-COA | /reports/CHART_OF_ACCOUNTS_REPORT | Not Started | |
| Chart of Groups Report | MST-RPT-GRP | /reports/CHART_OF_GROUPS_REPORT | Not Started | |
| Item Category Master Report | MST-RPT-ITC | /reports/ITEM_CATEGORY_MASTER_REPORT | Not Started | |
| Common Masters Report | MST-RPT-CMN | /reports/COMMON_MASTERS_REPORT | Not Started | |
| Tax Master Report | MST-RPT-TAX | /reports/TAX_MASTER_REPORT | Not Started | |
| Tax Group Master Report | MST-RPT-TXG | /reports/TAX_GROUP_MASTER_REPORT | Not Started | |
| Payment Terms Master Report | MST-RPT-PYT | /reports/PAYMENT_TERMS_MASTER_REPORT | Not Started | |
| Sales Executives Master Report | MST-RPT-SEX | /reports/SALES_EXECUTIVES_MASTER_REPORT | Not Started | |
| Additional Charges Master Report | MST-RPT-CHG | /reports/ADDITIONAL_CHARGES_MASTER_REPORT | Not Started | |
| Price List Report | MST-RPT-PRC | /reports/PRICE_LIST_REPORT | Not Started | |

---

## SL — Sales (21 screens)

### Transactions (8) — each has its own detail file in [`sales/`](sales/)
| Screen | Feature Code | Route | Detail File | Status | Open Bugs |
|---|---|---|---|---|---|
| Sales Quotation | SL-QUO | /sales/quotations | [sales_quotation.md](sales/sales_quotation.md) | Not Started | |
| Sales Order | SL-SO | /sales/orders | [sales_order.md](sales/sales_order.md) | Not Started | |
| Sales Invoice | SL-INV | /sales/invoices | [sales_invoice.md](sales/sales_invoice.md) | Not Started | |
| Pending Approvals | SL-INR | /sales/pending-approvals | [pending_approvals.md](sales/pending_approvals.md) | Not Started | |
| Sales Return | SL-RET | /sales/returns | [sales_return.md](sales/sales_return.md) | Not Started | |
| Sales Delivery | SL-DEL | /sales/deliveries | [sales_delivery.md](sales/sales_delivery.md) | Not Started | Buttons-stay-enabled bug fixed `a172574`, pending redeploy verification |
| Cash Receipt | SL-RCP | /sales/receipts | [cash_receipt.md](sales/cash_receipt.md) | Not Started | |
| Credit Sales Invoice | SL-CINV | /sales/credit-invoices | [credit_sales_invoice.md](sales/credit_sales_invoice.md) | Not Started | |

### Reports (13) — detail file: [`reports/sales_reports.md`](reports/sales_reports.md)
| Screen | Feature Code | Route | Status | Open Bugs |
|---|---|---|---|---|
| Sales Register | SL-RPT-REG | /reports/SALES_REGISTER | Not Started | |
| Item-wise Gross Profit | SL-RPT-IGP | /reports/ITEM_GROSS_PROFIT | Not Started | |
| Invoice-wise Gross Profit | SL-RPT-VGP | /reports/INVOICE_GROSS_PROFIT | Not Started | |
| Customer-wise Gross Profit | SL-RPT-CGP | /reports/CUSTOMER_GROSS_PROFIT | Not Started | |
| Salesperson-wise Performance | SL-RPT-SPP | /reports/SALESPERSON_PERFORMANCE | Not Started | |
| Sales Return Register | SL-RPT-RET | /reports/SALES_RETURN_REGISTER | Not Started | |
| Sales Quotation Register | SL-RPT-SQR | /reports/SALES_QUOTATION_REGISTER | Not Started | |
| Sales Order Register | SL-RPT-SOR | /reports/SALES_ORDER_REGISTER | Not Started | |
| Quotation Conversion Analysis | SL-RPT-QCA | /reports/QUOTATION_CONVERSION_ANALYSIS | Not Started | |
| Open Sales Orders | SL-RPT-OSO | /reports/OPEN_SALES_ORDERS | Not Started | |
| Sales Delivery Register | SL-RPT-SDR | /reports/SALES_DELIVERY_REGISTER | Not Started | |
| Pending Deliveries | SL-RPT-PDL | /reports/PENDING_DELIVERIES | Not Started | |
| Cash Receipt / Collections Register | SL-RPT-CRR | /reports/CASH_RECEIPT_REGISTER | Not Started | |

---

## PR — Purchase (18 screens)

### Transactions (5) — each has its own detail file in [`purchase/`](purchase/)
| Screen | Feature Code | Route | Detail File | Status | Open Bugs |
|---|---|---|---|---|---|
| Purchase Order | PR-PO | /purchase/orders | [purchase_order.md](purchase/purchase_order.md) | Not Started | |
| Goods Receipt (GRN) | PR-GRN | /purchase/grn | [grn.md](purchase/grn.md) | Not Started | |
| Purchase Invoice | PR-INV | /purchase/invoices | [purchase_invoice.md](purchase/purchase_invoice.md) | Not Started | |
| Purchase Return | PR-RET | /purchase/returns | [purchase_return.md](purchase/purchase_return.md) | Not Started | |
| Supplier Payment | PR-PAY | /purchase/payments | — | **N/A — Not Built** | Route is still a placeholder |

### Reports (13) — detail file: [`reports/purchase_reports.md`](reports/purchase_reports.md)
| Screen | Feature Code | Route | Status | Open Bugs |
|---|---|---|---|---|
| Purchase Order Register | PR-RPT-POR | /reports/PURCHASE_ORDER_REGISTER | Not Started | |
| Pending Purchase Orders | PR-RPT-PPO | /reports/PENDING_PURCHASE_ORDERS | Not Started | |
| GRN Register | PR-RPT-GRN | /reports/GRN_REGISTER | Not Started | |
| GRN Pending to Bill | PR-RPT-GPB | /reports/GRN_PENDING_TO_BILL | Not Started | |
| Purchase Invoice Register | PR-RPT-PIR | /reports/PURCHASE_INVOICE_REGISTER | Not Started | |
| Purchase Return Register | PR-RPT-PRR | /reports/PURCHASE_RETURN_REGISTER | Not Started | |
| Purchase Charges Register | PR-RPT-CHG | /reports/PURCHASE_CHARGES_REGISTER | Not Started | |
| Supplier-wise Purchase Analysis | PR-RPT-SUP | /reports/SUPPLIER_PURCHASE_ANALYSIS | Not Started | |
| Item-wise Purchase History | PR-RPT-ITM | /reports/ITEM_PURCHASE_HISTORY | Not Started | |
| Reorder / Replenishment | PR-RPT-ROR | /reports/REORDER_REPLENISHMENT | Not Started | |
| Vendor On-Time Delivery | PR-RPT-OTD | /reports/VENDOR_ON_TIME_DELIVERY | Not Started | |
| Purchase Price Variance | PR-RPT-PPV | /reports/PURCHASE_PRICE_VARIANCE | Not Started | |
| Purchase Tax Summary | PR-RPT-TAX | /reports/PURCHASE_TAX_SUMMARY | Not Started | |

---

## IN — Inventory (25 screens)

### Transactions (10) — each has its own detail file in [`inventory/`](inventory/)
| Screen | Feature Code | Route | Detail File | Status | Open Bugs |
|---|---|---|---|---|---|
| Stock List | IN-STK | /inventory/stock | — | **N/A — Not Built** | Route is still a placeholder |
| Stock Transfer | IN-TRF | /inventory/transfers | [stock_transfer.md](inventory/stock_transfer.md) | Not Started | |
| Stock Adjustment | IN-ADJ | /inventory/adjustments | [stock_adjustment.md](inventory/stock_adjustment.md) | Not Started | |
| Material Requisition | IN-MRQ | /inventory/requisitions | [material_requisition.md](inventory/material_requisition.md) | Not Started | |
| Material Issue | IN-MIS | /inventory/material-issue | [material_issue.md](inventory/material_issue.md) | Not Started | |
| Stock Transfer Request | IN-STR | /inventory/stock-transfer-requests | [stock_transfer_request.md](inventory/stock_transfer_request.md) | Not Started | |
| Stock Receipt | IN-SRC | /inventory/stock-receipts | [stock_receipt.md](inventory/stock_receipt.md) | Not Started | |
| Opening Stock | IN-OPN | /inventory/opening-stock | [opening_stock.md](inventory/opening_stock.md) | Not Started | |
| Stock Count | IN-CNT | /inventory/stock-count | [stock_count.md](inventory/stock_count.md) | Not Started | |
| Stock Count Review | IN-CNR | /inventory/stock-count-review | [stock_count_review.md](inventory/stock_count_review.md) | Not Started | |

### Reports (15) — detail file: [`reports/inventory_reports.md`](reports/inventory_reports.md)
| Screen | Feature Code | Route | Status | Open Bugs |
|---|---|---|---|---|
| Stock Balance by Location | IN-RPT-SBM | /reports/STOCK_BALANCE_MATRIX | Not Started | |
| Stock Value by Location | IN-RPT-SVL | /reports/STOCK_VALUE_BY_LOCATION | Not Started | |
| Stock Details | IN-RPT-SDT | /reports/STOCK_DETAILS | Not Started | |
| Stock Ledger | IN-RPT-SDL | /reports/STOCK_LEDGER | Not Started | |
| Stock Transfer Register | IN-RPT-STR | /reports/STOCK_TRANSFER_REGISTER | Not Started | |
| Pending Transfer to Receive | IN-RPT-STP | /reports/STOCK_TRANSFER_PENDING_RECEIPT | Not Started | |
| Stock Receipt Register | IN-RPT-SRR | /reports/STOCK_RECEIPT_REGISTER | Not Started | |
| Stock Adjustment Register | IN-RPT-SAD | /reports/STOCK_ADJUSTMENT_REGISTER | Not Started | |
| Stock Adjustment Register (with Value) | IN-RPT-SAV | /reports/STOCK_ADJUSTMENT_REGISTER_VALUE | Not Started | |
| Material Requisition Register | IN-RPT-MRQ | /reports/MATERIAL_REQUISITION_REGISTER | Not Started | |
| Material Issue Register | IN-RPT-MIS | /reports/MATERIAL_ISSUE_REGISTER | Not Started | |
| Stock Count Worksheet Register | IN-RPT-SCW | /reports/STOCK_COUNT_WORKSHEET_REGISTER | Not Started | |
| Stock Count Variance Report | IN-RPT-SCV | /reports/STOCK_COUNT_VARIANCE_REPORT | Not Started | |
| Stock Count Variance Report (with Value) | IN-RPT-SCV-V | /reports/STOCK_COUNT_VARIANCE_REPORT_VALUE | Not Started | |
| Product Movement Analysis | IN-RPT-PMA | /reports/PRODUCT_MOVEMENT_ANALYSIS | Not Started | |

---

## FN — Finance (30 screens)

### Transactions (5) — each has its own detail file in [`finance/`](finance/)
| Screen | Feature Code | Route | Detail File | Status | Open Bugs |
|---|---|---|---|---|---|
| Journal Entry | FN-JRN | /finance/journal | [journal_entry.md](finance/journal_entry.md) | Not Started | |
| Contra Voucher | FN-CTR | /finance/contra | [contra_voucher.md](finance/contra_voucher.md) | Not Started | |
| Expense Voucher | FN-EXP | /finance/expense-vouchers | [expense_voucher.md](finance/expense_voucher.md) | Not Started | |
| Cash Book | FN-CBK | /finance/cashbook | — | **N/A — Not Built** | Route is still a placeholder |
| Payment/Receipt Voucher | FN-PRV | /finance/voucher-list | [payment_receipt_voucher.md](finance/payment_receipt_voucher.md) | Not Started | Party-Amount bug fixed `a172574`, pending redeploy verification |

### Reports incl. Bank Reconciliation (21 + 4 = 25) — detail file: [`reports/finance_reports.md`](reports/finance_reports.md)
| Screen | Feature Code | Route | Status | Open Bugs |
|---|---|---|---|---|
| Trial Balance | FN-TRB | /reports/TRIAL_BALANCE | Not Started | |
| Profit & Loss | FN-PNL | /reports/PROFIT_LOSS_SUMMARY | Not Started | |
| Balance Sheet | FN-BSH | /reports/BALANCE_SHEET_SUMMARY | Not Started | |
| Pending Bills Register | FN-RPT-PBR | /reports/PENDING_BILLS_REGISTER | Not Started | |
| Pending Bills by Customer | FN-RPT-PBG | /reports/PENDING_BILLS_BY_CUSTOMER | Not Started | |
| **Account Ledger** | FN-RPT-LDG | /reports/ACCOUNT_LEDGER | Not Started | Dr/Cr + currency bugs fixed migration 184 (`a172574`), verified live vs. real data, pending redeploy verification |
| Customer Ageing | FN-RPT-CAG | /reports/CUSTOMER_AGEING | Not Started | |
| Supplier Ageing | FN-RPT-SAG | /reports/SUPPLIER_AGEING | Not Started | |
| Pending Bills by Supplier | FN-RPT-PBS | /reports/PENDING_BILLS_BY_SUPPLIER | Not Started | |
| Expense Report | FN-RPT-EXR | /reports/EXPENSE_REPORT_MATRIX | Not Started | |
| Profit & Loss Account Detail | FN-RPT-PNL | /reports/PROFIT_LOSS_DETAIL | Not Started | |
| Balance Sheet Account Detail | FN-RPT-BSD | /reports/BALANCE_SHEET_DETAIL | Not Started | |
| Cash Flow Summary | FN-RPT-CFS | /reports/CASH_FLOW_SUMMARY | Not Started | |
| Cash Flow Account Detail | FN-RPT-CFD | /reports/CASH_FLOW_DETAIL | Not Started | |
| Day Book / Voucher Register | FN-RPT-DBK | /reports/DAY_BOOK_REGISTER | Not Started | |
| Cheque Register | FN-RPT-CHQ | /reports/CHEQUE_REGISTER | Not Started | |
| VAT / Tax Return Summary | FN-RPT-VAT | /reports/VAT_TAX_RETURN_SUMMARY | Not Started | |
| Withholding Tax Summary | FN-RPT-WHT | /reports/WITHHOLDING_TAX_SUMMARY | Not Started | |
| Financial Ratio Analysis | FN-RPT-RAT | /reports/FINANCIAL_RATIO_ANALYSIS | Not Started | |
| Cash & Bank Position Summary | FN-RPT-CBP | /reports/CASH_BANK_POSITION_SUMMARY | Not Started | |
| Bank Reconciliation Statement | FN-RPT-BRS | /reports/BANK_RECONCILIATION_STATEMENT | Not Started | |

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
