class RouteNames {
  static const String landing   = '/';
  static const String login     = '/login';
  static const String register  = '/register';
  static const String dashboard = '/dashboard';

  // Group landing — dynamic, pass groupCode to groupPath()
  static const String group = '/group/:groupCode';
  static String groupPath(String groupCode) => '/group/$groupCode';

  // Auth (inside shell)
  static const String changePassword = '/auth/change-password';

  // Setup / Admin
  static const String masterMenu  = '/setup/master-menu';
  static const String company     = '/setup/company';
  static const String locations   = '/setup/locations';
  static const String locationGroups = '/setup/location-groups';
  static const String currencies  = '/setup/currencies';
  static const String countries   = '/setup/countries';
  static const String divisions   = '/setup/divisions';
  static const String cities      = '/setup/cities';
  static const String users       = '/setup/users';
  static const String userLocationAccess = '/setup/user-location-access';
  static const String permissions = '/setup/permissions';
  static const String quickInvoiceSetup = '/setup/quick-invoice-setup';
  static const String offlineSettings = '/setup/offline-settings';
  static const String periodClose = '/setup/period-close';
  static const String backdatedEntryControl = '/setup/backdated-entry-control';
  static const String printTemplates = '/setup/print-templates';
  static const String printTemplateDesigner = '/setup/print-templates/designer';

  // Sales — screen_names must match ric_master_menus seeds
  static const String salesQuotations    = '/sales/quotations';
  static const String salesQuotationEntry = '/sales/quotation-entry';
  static const String salesPriceMaster      = '/sales/price-master';
  static const String salesPriceMasterEntry = '/sales/price-master-entry';
  static const String salesOrders     = '/sales/orders';
  static const String salesOrderEntry = '/sales/order-entry';
  static const String salesInvoices = '/sales/invoices';
  static const String salesInvoiceEntry = '/sales/invoice-entry';
  static const String salesInvoiceManagerReview = '/sales/invoice-manager-review';
  static const String salesReturns  = '/sales/returns';
  static const String salesReceipts = '/sales/receipts';

  // Purchase
  static const String purchaseOrders   = '/purchase/orders';
  static const String purchaseOrderEntry = '/purchase/order-entry';
  static const String goodsReceipt     = '/purchase/grn';
  static const String grnEntry         = '/purchase/grn-entry';
  static const String purchaseInvoices = '/purchase/invoices';
  static const String purchaseInvoiceEntry = '/purchase/invoice-entry';
  static const String purchaseReturns = '/purchase/returns';
  static const String purchaseReturnEntry = '/purchase/return-entry';
  static const String supplierPayment  = '/purchase/payments';

  // Inventory
  static const String stockList       = '/inventory/stock';
  static const String stockTransfers  = '/inventory/transfers';
  static const String stockTransferEntry = '/inventory/transfer-entry';
  static const String stockAdjustments = '/inventory/adjustments';
  static const String stockAdjustmentEntry = '/inventory/adjustment-entry';
  static const String departmentConsumptionAreas = '/inventory/department-consumption-areas';
  static const String materialRequisitions      = '/inventory/requisitions';
  static const String materialRequisitionEntry  = '/inventory/requisition-entry';
  static const String materialIssues            = '/inventory/material-issue';
  static const String materialIssueEntry        = '/inventory/material-issue-entry';
  static const String stockTransferRequests     = '/inventory/stock-transfer-requests';
  static const String stockTransferRequestEntry = '/inventory/stock-transfer-request-entry';
  static const String openingStock              = '/inventory/opening-stock';
  static const String openingStockEntry         = '/inventory/opening-stock-entry';
  static const String stockCount                = '/inventory/stock-count';
  static const String stockCountEntry           = '/inventory/stock-count-entry';
  static const String stockCountReview          = '/inventory/stock-count-review';
  static const String stockCountReviewEntry     = '/inventory/stock-count-review-entry';
  static const String stockReceipts             = '/inventory/stock-receipts';
  static const String stockReceiptEntry         = '/inventory/stock-receipt-entry';

  // Accounting admin (Setup group)
  static const String accountingSetup  = '/setup/accounting';
  static const String financialYears   = '/setup/financial-years';

  // Master data
  static const String chartOfAccounts  = '/master/accounts';
  static const String customerMaster   = '/master/customers';
  static const String supplierMaster   = '/master/suppliers';
  static const String commonMasters    = '/master/common-masters';
  static const String categoryLevels   = '/setup/category-levels';
  static const String productFlagTypes = '/setup/product-flag-types';
  static const String itemCategories   = '/master/item-categories';
  static const String taxMaster        = '/master/tax-master';
  static const String taxGroups        = '/master/tax-groups';
  static const String additionalCharges = '/master/additional-charges';
  static const String paymentTerms      = '/master/payment-terms';
  static const String productMaster    = '/master/products';
  static const String productEntry     = '/master/product-entry';
  static const String accountLinkSetup     = '/master/account-link-setup';
  static const String accountLinkConfigure = '/master/account-link-configure';
  static const String itemAccountLinks     = '/master/item-account-links';

  // Finance
  static const String exchangeRates  = '/finance/exchange-rates';
  static const String paymentReceipt = '/finance/payment-receipt';
  static const String voucherList    = '/finance/voucher-list';
  static const String journalEntry   = '/finance/journal';
  static const String cashBook       = '/finance/cashbook';
  static const String trialBalance   = '/finance/trial-balance';
  static const String profitLoss     = '/finance/profit-loss';
  static const String balanceSheet   = '/finance/balance-sheet';

  // Offline sync — shown once after online login when pending docs exist
  static const String sync = '/sync';
}
