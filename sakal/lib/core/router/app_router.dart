import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../features/auth/presentation/screens/change_password_screen.dart';
import '../../features/auth/presentation/screens/landing_screen.dart';
import '../../features/auth/presentation/screens/login_screen.dart';
import '../../features/auth/presentation/screens/register_screen.dart';
import '../../features/auth/presentation/screens/sync_screen.dart';
import '../../features/dashboard/presentation/screens/dashboard_screen.dart';
import '../../features/setup/presentation/screens/company_screen.dart';
import '../../features/setup/presentation/screens/cities_screen.dart';
import '../../features/setup/presentation/screens/countries_screen.dart';
import '../../features/setup/presentation/screens/currencies_screen.dart';
import '../../features/setup/presentation/screens/divisions_screen.dart';
import '../../features/setup/presentation/screens/locations_screen.dart';
import '../../features/setup/presentation/screens/location_groups_screen.dart';
import '../../features/setup/presentation/screens/master_menu_screen.dart';
import '../../features/setup/presentation/screens/permissions_screen.dart';
import '../../features/setup/presentation/screens/quick_invoice_setup_screen.dart';
import '../../features/setup/presentation/screens/offline_settings_screen.dart';
import '../../features/setup/presentation/screens/users_screen.dart';
import '../../features/setup/presentation/screens/user_location_access_screen.dart';
import '../../features/setup/presentation/screens/accounting_setup_screen.dart';
import '../../features/setup/presentation/screens/period_close_screen.dart';
import '../../features/setup/presentation/screens/backdated_entry_control_screen.dart';
import '../../features/setup/presentation/screens/print_template_list_screen.dart';
import '../../features/setup/presentation/screens/print_template_designer_screen.dart';
import '../../features/master/presentation/screens/chart_of_accounts_screen.dart';
import '../../features/master/presentation/screens/common_masters_screen.dart';
import '../../features/master/presentation/screens/customer_master_screen.dart';
import '../../features/master/presentation/screens/item_categories_screen.dart';
import '../../features/master/presentation/screens/supplier_master_screen.dart';
import '../../features/master/presentation/screens/tax_master_screen.dart';
import '../../features/master/presentation/screens/tax_groups_screen.dart';
import '../../features/master/presentation/screens/additional_charges_screen.dart';
import '../../features/master/presentation/screens/payment_terms_screen.dart';
import '../../features/master/presentation/screens/account_link_setup_screen.dart';
import '../../features/master/presentation/screens/account_link_configure_screen.dart';
import '../../features/master/presentation/screens/item_account_links_screen.dart';
import '../../features/inventory/presentation/screens/department_consumption_area_screen.dart';
import '../../features/inventory/presentation/screens/material_requisition_list_screen.dart';
import '../../features/inventory/presentation/screens/material_requisition_entry_screen.dart';
import '../../features/inventory/presentation/screens/material_issue_list_screen.dart';
import '../../features/inventory/presentation/screens/material_issue_entry_screen.dart';
import '../../features/inventory/presentation/screens/stock_adjustment_list_screen.dart';
import '../../features/inventory/presentation/screens/stock_adjustment_entry_screen.dart';
import '../../features/inventory/presentation/screens/stock_transfer_request_list_screen.dart';
import '../../features/inventory/presentation/screens/stock_transfer_request_entry_screen.dart';
import '../../features/inventory/presentation/screens/stock_transfer_list_screen.dart';
import '../../features/inventory/presentation/screens/stock_transfer_entry_screen.dart';
import '../../features/inventory/presentation/screens/stock_receipt_list_screen.dart';
import '../../features/inventory/presentation/screens/stock_receipt_entry_screen.dart';
import '../../features/inventory/presentation/screens/opening_stock_list_screen.dart';
import '../../features/inventory/presentation/screens/opening_stock_entry_screen.dart';
import '../../features/inventory/presentation/screens/stock_count_list_screen.dart';
import '../../features/inventory/presentation/screens/stock_count_entry_screen.dart';
import '../../features/inventory/presentation/screens/stock_count_review_list_screen.dart';
import '../../features/inventory/presentation/screens/stock_count_review_entry_screen.dart';
import '../../features/sales/presentation/screens/sales_quotation_list_screen.dart';
import '../../features/sales/presentation/screens/sales_quotation_entry_screen.dart';
import '../../features/sales/presentation/screens/price_master_list_screen.dart';
import '../../features/master/presentation/screens/sales_executive_master_screen.dart';
import '../../features/sales/presentation/screens/price_master_entry_screen.dart';
import '../../features/sales/presentation/screens/sales_order_list_screen.dart';
import '../../features/sales/presentation/screens/sales_order_entry_screen.dart';
import '../../features/sales/presentation/screens/sales_invoice_list_screen.dart';
import '../../features/sales/presentation/screens/sales_invoice_entry_screen.dart';
import '../../features/sales/presentation/screens/sales_pending_approvals_screen.dart';
import '../../features/sales/presentation/screens/sales_return_list_screen.dart';
import '../../features/sales/presentation/screens/sales_return_entry_screen.dart';
import '../../features/sales/presentation/screens/sales_delivery_list_screen.dart';
import '../../features/sales/presentation/screens/sales_delivery_entry_screen.dart';
import '../../features/purchase/presentation/screens/purchase_order_list_screen.dart';
import '../../features/purchase/presentation/screens/purchase_order_entry_screen.dart';
import '../../features/purchase/presentation/screens/grn_list_screen.dart';
import '../../features/purchase/presentation/screens/grn_entry_screen.dart';
import '../../features/purchase/presentation/screens/purchase_invoice_list_screen.dart';
import '../../features/purchase/presentation/screens/purchase_invoice_entry_screen.dart';
import '../../features/purchase/presentation/screens/purchase_return_list_screen.dart';
import '../../features/purchase/presentation/screens/purchase_return_entry_screen.dart';
import '../../features/master/presentation/screens/product_list_screen.dart';
import '../../features/master/presentation/screens/product_entry_screen.dart';
import '../../features/setup/presentation/screens/category_levels_screen.dart';
import '../../features/setup/presentation/screens/product_flag_types_screen.dart';
import '../../features/finance/presentation/screens/exchange_rate_screen.dart';
import '../../features/finance/presentation/screens/finance_voucher_entry_screen.dart';
import '../../features/finance/presentation/screens/finance_voucher_list_screen.dart';
import '../layout/app_shell.dart';
import '../layout/group_landing_screen.dart';
import '../providers/session_provider.dart';
import '../services/local_storage.dart';
import 'route_names.dart';

// Mirrors sessionProvider state so GoRouter can listen and re-evaluate redirects
// whenever the user logs in, logs out, or the session is restored on page refresh.
final sessionNotifier = ValueNotifier<UserSession?>(null);

final appRouter = GoRouter(
  initialLocation: RouteNames.landing,
  refreshListenable: sessionNotifier,
  debugLogDiagnostics: true,
  redirect: (context, state) {
    final loc       = state.matchedLocation;
    final hasClient = LocalStorage.clientNo != null;
    final session   = sessionNotifier.value;

    // Always allow registration and sync routes regardless of auth state.
    if (loc == RouteNames.register) return null;
    if (loc == RouteNames.sync)     return null;

    // No cached client → allow landing and login (login screen shows Client ID field).
    // Blocks everything else until the user either registers or signs in.
    if (!hasClient) {
      if (loc == RouteNames.landing || loc == RouteNames.login) return null;
      return RouteNames.landing;
    }

    // Client registered but not logged in → force login.
    if (session == null) {
      return loc == RouteNames.login ? null : RouteNames.login;
    }

    // Logged in — don't let them land on login/landing again.
    if (loc == RouteNames.login || loc == RouteNames.landing) {
      return RouteNames.dashboard;
    }

    return null;
  },
  routes: [
    // Outer shell — only purpose is SelectionArea for app-wide text selection.
    // Must be inside a route (i.e., inside the Navigator) so that the Overlay
    // ancestor required by SelectionArea already exists.
    ShellRoute(
      builder: (context, state, child) => SelectionArea(child: child),
      routes: [

    // Public routes
    GoRoute(path: RouteNames.landing,  builder: (c, s) => const LandingScreen()),
    GoRoute(path: RouteNames.login,    builder: (c, s) => const LoginScreen()),
    GoRoute(path: RouteNames.register, builder: (c, s) => const RegisterScreen()),
    GoRoute(path: RouteNames.sync,     builder: (c, s) => const SyncScreen()),

    // Authenticated routes — all wrapped in AppShell (sidebar + topbar)
    ShellRoute(
      builder: (context, state, child) => AppShell(child: child),
      routes: [
        GoRoute(
          path: RouteNames.dashboard,
          builder: (c, s) => const DashboardScreen(),
        ),

        // Group landing — dynamic, used by sidebar group headers
        GoRoute(
          path: RouteNames.group,
          builder: (c, s) => GroupLandingScreen(
              groupCode: s.pathParameters['groupCode']!),
        ),

        // Auth (inside shell)
        GoRoute(path: RouteNames.changePassword, builder: (c, s) => const ChangePasswordScreen()),

        // Administration
        GoRoute(path: RouteNames.masterMenu,  builder: (c, s) => const MasterMenuScreen()),
        GoRoute(path: RouteNames.company,     builder: (c, s) => const CompanyScreen()),
        GoRoute(path: RouteNames.locations,   builder: (c, s) => const LocationsScreen()),
        GoRoute(path: RouteNames.locationGroups, builder: (c, s) => const LocationGroupsScreen()),
        GoRoute(path: RouteNames.currencies,  builder: (c, s) => const CurrenciesScreen()),
        GoRoute(path: RouteNames.countries,   builder: (c, s) => const CountriesScreen()),
        GoRoute(path: RouteNames.divisions,   builder: (c, s) => const DivisionsScreen()),
        GoRoute(path: RouteNames.cities,      builder: (c, s) => const CitiesScreen()),
        GoRoute(path: RouteNames.users,          builder: (c, s) => const UsersScreen()),
        GoRoute(path: RouteNames.userLocationAccess, builder: (c, s) => const UserLocationAccessScreen()),
        GoRoute(path: RouteNames.permissions,    builder: (c, s) => const PermissionsScreen()),
        GoRoute(path: RouteNames.quickInvoiceSetup, builder: (c, s) => const QuickInvoiceSetupScreen()),
        GoRoute(path: RouteNames.offlineSettings, builder: (c, s) => const OfflineSettingsScreen()),
        GoRoute(path: RouteNames.accountingSetup,builder: (c, s) => const AccountingSetupScreen()),
        GoRoute(path: RouteNames.financialYears, builder: (c, s) => const _Placeholder('Financial Years')),
        GoRoute(path: RouteNames.periodClose,    builder: (c, s) => const PeriodCloseScreen()),
        GoRoute(path: RouteNames.backdatedEntryControl, builder: (c, s) => const BackdatedEntryControlScreen()),
        GoRoute(path: RouteNames.printTemplates, builder: (c, s) => const PrintTemplateListScreen()),
        GoRoute(
          path: RouteNames.printTemplateDesigner,
          builder: (c, s) {
            final extra = s.extra as Map<String, dynamic>?;
            return PrintTemplateDesignerScreen(
              templateId:  extra?['templateId'] as String?,
              documentType: extra?['documentType'] as String?,
            );
          },
        ),

        // Master data
        GoRoute(path: RouteNames.chartOfAccounts,builder: (c, s) => const ChartOfAccountsScreen()),
        GoRoute(path: RouteNames.customerMaster, builder: (c, s) => const CustomerMasterScreen()),
        GoRoute(path: RouteNames.supplierMaster, builder: (c, s) => const SupplierMasterScreen()),
        GoRoute(path: RouteNames.commonMasters,  builder: (c, s) => const CommonMastersScreen()),
        GoRoute(path: RouteNames.itemCategories, builder: (c, s) => const ItemCategoriesScreen()),
        GoRoute(path: RouteNames.taxMaster,      builder: (c, s) => const TaxMasterScreen()),
        GoRoute(path: RouteNames.taxGroups,      builder: (c, s) => const TaxGroupsScreen()),
        GoRoute(path: RouteNames.additionalCharges, builder: (c, s) => const AdditionalChargesScreen()),
        GoRoute(path: RouteNames.paymentTerms,   builder: (c, s) => const PaymentTermsScreen()),
        GoRoute(path: RouteNames.accountLinkSetup, builder: (c, s) => const AccountLinkSetupScreen()),
        GoRoute(
          path: RouteNames.accountLinkConfigure,
          builder: (c, s) {
            final extra = s.extra as Map<String, dynamic>?;
            return AccountLinkConfigureScreen(
              linkTypeId: extra?['linkTypeId'] as String? ?? '',
              linkKey:    extra?['linkKey']    as String? ?? '',
              linkName:   extra?['linkName']   as String? ?? '',
            );
          },
        ),
        GoRoute(path: RouteNames.itemAccountLinks, builder: (c, s) => const ItemAccountLinksScreen()),
        GoRoute(path: RouteNames.productMaster,  builder: (c, s) => const ProductListScreen()),
        GoRoute(
          path: RouteNames.productEntry,
          builder: (c, s) {
            final extra = s.extra as Map<String, dynamic>?;
            return ProductEntryScreen(
              productId: extra?['productId'] as String?,
            );
          },
        ),

        // Setup additions
        GoRoute(path: RouteNames.categoryLevels,   builder: (c, s) => const CategoryLevelsScreen()),
        GoRoute(path: RouteNames.productFlagTypes, builder: (c, s) => const ProductFlagTypesScreen()),

        // Sales
        GoRoute(path: RouteNames.salesQuotations, builder: (c, s) => const SalesQuotationListScreen()),
        GoRoute(
          path: RouteNames.salesQuotationEntry,
          builder: (c, s) {
            final extra = s.extra as Map<String, dynamic>?;
            return SalesQuotationEntryScreen(
              editQuotationNo:   extra?['quotationNo']   as String?,
              editQuotationDate: extra?['quotationDate'] as String?,
            );
          },
        ),
        GoRoute(path: RouteNames.salesPriceMaster, builder: (c, s) => const PriceMasterListScreen()),
        GoRoute(path: RouteNames.salesExecutives, builder: (c, s) => const SalesExecutiveMasterScreen()),
        GoRoute(
          path: RouteNames.salesPriceMasterEntry,
          builder: (c, s) {
            final extra = s.extra as Map<String, dynamic>?;
            return PriceMasterEntryScreen(
              editEntryNo:   extra?['entryNo']   as String?,
              editEntryDate: extra?['entryDate'] as String?,
            );
          },
        ),
        GoRoute(path: RouteNames.salesOrders, builder: (c, s) => const SalesOrderListScreen()),
        GoRoute(
          path: RouteNames.salesOrderEntry,
          builder: (c, s) {
            final extra = s.extra as Map<String, dynamic>?;
            return SalesOrderEntryScreen(
              editOrderNo:         extra?['orderNo'] as String?,
              editOrderDate:       extra?['orderDate'] as String?,
              newOrderMode:        extra?['newOrderMode'] as String?,
              sourceQuotationNo:   extra?['sourceQuotationNo'] as String?,
              sourceQuotationDate: extra?['sourceQuotationDate'] as String?,
            );
          },
        ),
        GoRoute(path: RouteNames.salesInvoices, builder: (c, s) => const SalesInvoiceListScreen()),
        GoRoute(
          path: RouteNames.salesInvoiceEntry,
          builder: (c, s) {
            final extra = s.extra as Map<String, dynamic>?;
            return SalesInvoiceEntryScreen(
              editInvoiceNo:       extra?['invoiceNo'] as String?,
              editInvoiceDate:     extra?['invoiceDate'] as String?,
              newInvoiceMode:      extra?['newInvoiceMode'] as String?,
              sourceQuotationNo:   extra?['sourceQuotationNo'] as String?,
              sourceQuotationDate: extra?['sourceQuotationDate'] as String?,
              sourceOrderNo:       extra?['sourceOrderNo'] as String?,
              sourceOrderDate:     extra?['sourceOrderDate'] as String?,
            );
          },
        ),
        GoRoute(path: RouteNames.salesPendingApprovals, builder: (c, s) => const SalesPendingApprovalsScreen()),
        GoRoute(path: RouteNames.salesReturns, builder: (c, s) => const SalesReturnListScreen()),
        GoRoute(
          path: RouteNames.salesReturnEntry,
          builder: (c, s) {
            final extra = s.extra as Map<String, dynamic>?;
            return SalesReturnEntryScreen(
              editReturnNo:   extra?['returnNo'] as String?,
              editReturnDate: extra?['returnDate'] as String?,
            );
          },
        ),
        GoRoute(path: RouteNames.salesDeliveries, builder: (c, s) => const SalesDeliveryListScreen()),
        GoRoute(
          path: RouteNames.salesDeliveryEntry,
          builder: (c, s) {
            final extra = s.extra as Map<String, dynamic>?;
            return SalesDeliveryEntryScreen(
              editDeliveryNo:   extra?['deliveryNo'] as String?,
              editDeliveryDate: extra?['deliveryDate'] as String?,
            );
          },
        ),
        GoRoute(path: RouteNames.salesReceipts, builder: (c, s) => const _Placeholder('Cash Receipt')),

        // Purchase
        GoRoute(path: RouteNames.purchaseOrders, builder: (c, s) => const PurchaseOrderListScreen()),
        GoRoute(
          path: RouteNames.purchaseOrderEntry,
          builder: (c, s) {
            final extra = s.extra as Map<String, dynamic>?;
            return PurchaseOrderEntryScreen(
              editOrderNo:   extra?['orderNo']   as String?,
              editOrderDate: extra?['orderDate'] as String?,
            );
          },
        ),
        GoRoute(path: RouteNames.goodsReceipt, builder: (c, s) => const GrnListScreen()),
        GoRoute(
          path: RouteNames.grnEntry,
          builder: (c, s) {
            final extra = s.extra as Map<String, dynamic>?;
            return GrnEntryScreen(
              editGrnNo:   extra?['grnNo']   as String?,
              editGrnDate: extra?['grnDate'] as String?,
            );
          },
        ),
        GoRoute(path: RouteNames.purchaseInvoices, builder: (c, s) => const PurchaseInvoiceListScreen()),
        GoRoute(
          path: RouteNames.purchaseInvoiceEntry,
          builder: (c, s) {
            final extra = s.extra as Map<String, dynamic>?;
            return PurchaseInvoiceEntryScreen(
              editInvoiceNo:   extra?['invoiceNo']   as String?,
              editInvoiceDate: extra?['invoiceDate'] as String?,
            );
          },
        ),
        GoRoute(path: RouteNames.purchaseReturns, builder: (c, s) => const PurchaseReturnListScreen()),
        GoRoute(
          path: RouteNames.purchaseReturnEntry,
          builder: (c, s) {
            final extra = s.extra as Map<String, dynamic>?;
            return PurchaseReturnEntryScreen(
              editReturnNo:   extra?['returnNo']   as String?,
              editReturnDate: extra?['returnDate'] as String?,
            );
          },
        ),
        GoRoute(path: RouteNames.supplierPayment,  builder: (c, s) => const _Placeholder('Supplier Payment')),

        // Inventory
        GoRoute(path: RouteNames.stockList,        builder: (c, s) => const _Placeholder('Stock List')),
        GoRoute(path: RouteNames.stockTransfers,   builder: (c, s) => const StockTransferListScreen()),
        GoRoute(
          path: RouteNames.stockTransferEntry,
          builder: (c, s) {
            final extra = s.extra as Map<String, dynamic>?;
            return StockTransferEntryScreen(
              editTransferNo:   extra?['transferNo']   as String?,
              editTransferDate: extra?['transferDate'] as String?,
            );
          },
        ),
        GoRoute(path: RouteNames.stockAdjustments, builder: (c, s) => const StockAdjustmentListScreen()),
        GoRoute(
          path: RouteNames.stockAdjustmentEntry,
          builder: (c, s) {
            final extra = s.extra as Map<String, dynamic>?;
            return StockAdjustmentEntryScreen(
              editAdjustmentNo:   extra?['adjustmentNo']   as String?,
              editAdjustmentDate: extra?['adjustmentDate'] as String?,
            );
          },
        ),
        GoRoute(path: RouteNames.departmentConsumptionAreas, builder: (c, s) => const DepartmentConsumptionAreaScreen()),
        GoRoute(path: RouteNames.materialRequisitions, builder: (c, s) => const MaterialRequisitionListScreen()),
        GoRoute(
          path: RouteNames.materialRequisitionEntry,
          builder: (c, s) {
            final extra = s.extra as Map<String, dynamic>?;
            return MaterialRequisitionEntryScreen(
              editRequisitionNo:   extra?['requisitionNo']   as String?,
              editRequisitionDate: extra?['requisitionDate'] as String?,
            );
          },
        ),
        GoRoute(path: RouteNames.materialIssues, builder: (c, s) => const MaterialIssueListScreen()),
        GoRoute(
          path: RouteNames.materialIssueEntry,
          builder: (c, s) {
            final extra = s.extra as Map<String, dynamic>?;
            return MaterialIssueEntryScreen(
              editIssueNo:   extra?['issueNo']   as String?,
              editIssueDate: extra?['issueDate'] as String?,
            );
          },
        ),
        GoRoute(path: RouteNames.stockTransferRequests, builder: (c, s) => const StockTransferRequestListScreen()),
        GoRoute(
          path: RouteNames.stockTransferRequestEntry,
          builder: (c, s) {
            final extra = s.extra as Map<String, dynamic>?;
            return StockTransferRequestEntryScreen(
              editRequestNo:   extra?['requestNo']   as String?,
              editRequestDate: extra?['requestDate'] as String?,
            );
          },
        ),
        GoRoute(path: RouteNames.stockReceipts, builder: (c, s) => const StockReceiptListScreen()),
        GoRoute(
          path: RouteNames.stockReceiptEntry,
          builder: (c, s) {
            final extra = s.extra as Map<String, dynamic>?;
            return StockReceiptEntryScreen(
              editReceiptNo:   extra?['receiptNo']   as String?,
              editReceiptDate: extra?['receiptDate'] as String?,
            );
          },
        ),
        GoRoute(path: RouteNames.openingStock, builder: (c, s) => const OpeningStockListScreen()),
        GoRoute(
          path: RouteNames.openingStockEntry,
          builder: (c, s) {
            final extra = s.extra as Map<String, dynamic>?;
            return OpeningStockEntryScreen(
              editOpeningNo:   extra?['openingNo']   as String?,
              editOpeningDate: extra?['openingDate'] as String?,
            );
          },
        ),
        GoRoute(path: RouteNames.stockCount, builder: (c, s) => const StockCountListScreen()),
        GoRoute(
          path: RouteNames.stockCountEntry,
          builder: (c, s) {
            final extra = s.extra as Map<String, dynamic>?;
            return StockCountEntryScreen(
              editCountNo:   extra?['countNo']   as String?,
              editCountDate: extra?['countDate'] as String?,
            );
          },
        ),
        GoRoute(path: RouteNames.stockCountReview, builder: (c, s) => const StockCountReviewListScreen()),
        GoRoute(
          path: RouteNames.stockCountReviewEntry,
          builder: (c, s) {
            final extra = s.extra as Map<String, dynamic>?;
            return StockCountReviewEntryScreen(
              editReviewNo:   extra?['reviewNo']   as String?,
              editReviewDate: extra?['reviewDate'] as String?,
            );
          },
        ),

        // Finance
        GoRoute(path: RouteNames.exchangeRates, builder: (c, s) => const ExchangeRateScreen()),
        GoRoute(
          path: RouteNames.paymentReceipt,
          builder: (c, s) {
            final extra = s.extra as Map<String, dynamic>?;
            return FinanceVoucherEntryScreen(
              initialVoucherType: extra?['voucherType'] as String?,
              editTransNo:        extra?['transNo']     as String?,
              editTransDate:      extra?['transDate']   as String?,
            );
          },
        ),
        GoRoute(path: RouteNames.voucherList,   builder: (c, s) => const FinanceVoucherListScreen()),
        GoRoute(path: RouteNames.journalEntry,  builder: (c, s) => const _Placeholder('Journal Entry')),
        GoRoute(path: RouteNames.cashBook,     builder: (c, s) => const _Placeholder('Cash Book')),
        GoRoute(path: RouteNames.trialBalance, builder: (c, s) => const _Placeholder('Trial Balance')),
        GoRoute(path: RouteNames.profitLoss,   builder: (c, s) => const _Placeholder('Profit & Loss')),
        GoRoute(path: RouteNames.balanceSheet, builder: (c, s) => const _Placeholder('Balance Sheet')),
      ],
    ),

      ]), // outer SelectionArea ShellRoute
  ],
);

class _Placeholder extends StatelessWidget {
  final String title;
  const _Placeholder(this.title);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.construction_outlined,
              size: 48, color: Color(0xFFADB5BD)),
          const SizedBox(height: 16),
          Text(title,
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1A1D23))),
          const SizedBox(height: 8),
          const Text('Coming soon',
              style: TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
        ],
      ),
    );
  }
}
