import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../features/auth/presentation/screens/change_password_screen.dart';
import '../../features/auth/presentation/screens/landing_screen.dart';
import '../../features/auth/presentation/screens/login_screen.dart';
import '../../features/auth/presentation/screens/register_screen.dart';
import '../../features/dashboard/presentation/screens/dashboard_screen.dart';
import '../../features/setup/presentation/screens/company_screen.dart';
import '../../features/setup/presentation/screens/master_menu_screen.dart';
import '../layout/app_shell.dart';
import '../layout/group_landing_screen.dart';
import '../services/local_storage.dart';
import 'route_names.dart';

final appRouter = GoRouter(
  initialLocation: RouteNames.landing,
  debugLogDiagnostics: true,
  redirect: (context, state) {
    final loc       = state.matchedLocation;
    final hasClient = LocalStorage.clientNo != null;

    if (loc == RouteNames.register) return null;
    if (!hasClient && loc != RouteNames.landing) return RouteNames.landing;
    if (hasClient && loc == RouteNames.landing)  return RouteNames.login;
    return null;
  },
  routes: [
    // Public routes
    GoRoute(path: RouteNames.landing,  builder: (c, s) => const LandingScreen()),
    GoRoute(path: RouteNames.login,    builder: (c, s) => const LoginScreen()),
    GoRoute(path: RouteNames.register, builder: (c, s) => const RegisterScreen()),

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
        GoRoute(path: RouteNames.locations,   builder: (c, s) => const _Placeholder('Location Setup')),
        GoRoute(path: RouteNames.currencies,  builder: (c, s) => const _Placeholder('Currency Setup')),
        GoRoute(path: RouteNames.users,       builder: (c, s) => const _Placeholder('User Management')),
        GoRoute(path: RouteNames.permissions, builder: (c, s) => const _Placeholder('User Permissions')),

        // Sales
        GoRoute(path: RouteNames.salesInvoices, builder: (c, s) => const _Placeholder('Sales Invoice')),
        GoRoute(path: RouteNames.salesReturns,  builder: (c, s) => const _Placeholder('Sales Return')),
        GoRoute(path: RouteNames.salesReceipts, builder: (c, s) => const _Placeholder('Cash Receipt')),

        // Purchase
        GoRoute(path: RouteNames.purchaseOrders,   builder: (c, s) => const _Placeholder('Purchase Order')),
        GoRoute(path: RouteNames.goodsReceipt,     builder: (c, s) => const _Placeholder('Goods Receipt')),
        GoRoute(path: RouteNames.purchaseInvoices, builder: (c, s) => const _Placeholder('Purchase Invoice')),
        GoRoute(path: RouteNames.supplierPayment,  builder: (c, s) => const _Placeholder('Supplier Payment')),

        // Inventory
        GoRoute(path: RouteNames.stockList,        builder: (c, s) => const _Placeholder('Stock List')),
        GoRoute(path: RouteNames.stockTransfers,   builder: (c, s) => const _Placeholder('Stock Transfer')),
        GoRoute(path: RouteNames.stockAdjustments, builder: (c, s) => const _Placeholder('Stock Adjustment')),

        // Finance
        GoRoute(path: RouteNames.journalEntry, builder: (c, s) => const _Placeholder('Journal Entry')),
        GoRoute(path: RouteNames.cashBook,     builder: (c, s) => const _Placeholder('Cash Book')),
        GoRoute(path: RouteNames.trialBalance, builder: (c, s) => const _Placeholder('Trial Balance')),
        GoRoute(path: RouteNames.profitLoss,   builder: (c, s) => const _Placeholder('Profit & Loss')),
        GoRoute(path: RouteNames.balanceSheet, builder: (c, s) => const _Placeholder('Balance Sheet')),
      ],
    ),
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
