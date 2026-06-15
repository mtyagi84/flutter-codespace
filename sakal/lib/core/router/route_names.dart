class RouteNames {
  static const String landing   = '/';
  static const String login     = '/login';
  static const String register  = '/register';
  static const String dashboard = '/dashboard';

  // Sales
  static const String sales = '/sales';
  static const String salesInvoices = '/sales/invoices';
  static const String salesInvoiceNew = '/sales/invoices/new';
  static const String salesInvoiceDetail = '/sales/invoices/:id';
  static const String salesReturn = '/sales/returns/new';
  static const String cashReceipt = '/sales/receipts/new';

  // Purchase
  static const String purchase = '/purchase';
  static const String purchaseOrders = '/purchase/orders';
  static const String purchaseInvoices = '/purchase/invoices';
  static const String supplierPayment = '/purchase/payments/new';

  // Inventory
  static const String inventory = '/inventory';
  static const String stockList = '/inventory/stock';
  static const String stockTransfer = '/inventory/transfers/new';
  static const String stockAdjustment = '/inventory/adjustments/new';

  // Finance
  static const String finance = '/finance';
  static const String journalEntry = '/finance/journal/new';
  static const String cashBook = '/finance/cashbook';
  static const String trialBalance = '/finance/trial-balance';
  static const String profitLoss = '/finance/profit-loss';
  static const String balanceSheet = '/finance/balance-sheet';

  // Master
  static const String customers = '/master/customers';
  static const String suppliers = '/master/suppliers';
  static const String products = '/master/products';
  static const String chartOfAccounts = '/master/accounts';
  static const String uom = '/master/uom';
  static const String taxCodes = '/master/tax-codes';

  // Setup & Admin
  static const String setup = '/setup';
  static const String users = '/setup/users';
  static const String permissions = '/setup/permissions';
  static const String currencies = '/setup/currencies';
  static const String company = '/setup/company';
  static const String locations = '/setup/locations';
}
