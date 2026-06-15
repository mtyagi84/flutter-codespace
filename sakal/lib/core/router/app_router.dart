import 'package:go_router/go_router.dart';
import '../../features/auth/presentation/screens/landing_screen.dart';
import '../../features/auth/presentation/screens/login_screen.dart';
import '../../features/auth/presentation/screens/register_screen.dart';
import '../../features/dashboard/presentation/screens/dashboard_screen.dart';
import '../layout/app_shell.dart';
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
    GoRoute(
      path: RouteNames.landing,
      builder: (context, state) => const LandingScreen(),
    ),
    GoRoute(
      path: RouteNames.login,
      builder: (context, state) => const LoginScreen(),
    ),
    GoRoute(
      path: RouteNames.register,
      builder: (context, state) => const RegisterScreen(),
    ),

    // Authenticated routes — all wrapped in AppShell
    ShellRoute(
      builder: (context, state, child) => AppShell(child: child),
      routes: [
        GoRoute(
          path: RouteNames.dashboard,
          builder: (context, state) => const DashboardScreen(),
        ),
        GoRoute(
          path: RouteNames.company,
          builder: (context, state) => const PlaceholderScreen(title: 'Company Setup'),
        ),
        GoRoute(
          path: RouteNames.users,
          builder: (context, state) => const PlaceholderScreen(title: 'User Management'),
        ),
        GoRoute(
          path: RouteNames.permissions,
          builder: (context, state) => const PlaceholderScreen(title: 'User Permissions'),
        ),
        GoRoute(
          path: RouteNames.locations,
          builder: (context, state) => const PlaceholderScreen(title: 'Location Setup'),
        ),
        GoRoute(
          path: RouteNames.currencies,
          builder: (context, state) => const PlaceholderScreen(title: 'Currency Setup'),
        ),
      ],
    ),
  ],
);

// Temporary placeholder until each screen is built
class PlaceholderScreen extends StatelessWidget {
  final String title;
  const PlaceholderScreen({required this.title, super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(title,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
    );
  }
}
