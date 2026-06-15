class RouteNames {
  static const String landing   = '/';
  static const String login     = '/login';
  static const String register  = '/register';
  static const String dashboard = '/dashboard';

  // Group landing — dynamic, pass groupCode to groupPath()
  static const String group = '/group/:groupCode';
  static String groupPath(String groupCode) => '/group/$groupCode';

  // Setup / Admin
  static const String company     = '/setup/company';
  static const String locations   = '/setup/locations';
  static const String currencies  = '/setup/currencies';
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

  // Finance
  static const String journalEntry  = '/finance/journal';
  static const String cashBook      = '/finance/cashbook';
  static const String trialBalance  = '/finance/trial-balance';
  static const String profitLoss    = '/finance/profit-loss';
  static const String balanceSheet  = '/finance/balance-sheet';
}
