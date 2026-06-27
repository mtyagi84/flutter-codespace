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
  static const String currencies  = '/setup/currencies';
  static const String countries   = '/setup/countries';
  static const String divisions   = '/setup/divisions';
  static const String cities      = '/setup/cities';
  static const String users       = '/setup/users';
  static const String permissions = '/setup/permissions';

  // Sales — screen_names must match ric_master_menus seeds
  static const String salesInvoices = '/sales/invoices';
  static const String salesReturns  = '/sales/returns';
  static const String salesReceipts = '/sales/receipts';

  // Purchase
  static const String purchaseOrders   = '/purchase/orders';
  static const String goodsReceipt     = '/purchase/grn';
  static const String purchaseInvoices = '/purchase/invoices';
  static const String supplierPayment  = '/purchase/payments';

  // Inventory
  static const String stockList       = '/inventory/stock';
  static const String stockTransfers  = '/inventory/transfers';
  static const String stockAdjustments = '/inventory/adjustments';

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
