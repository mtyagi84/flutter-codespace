import 'package:go_router/go_router.dart';
import '../../features/auth/presentation/screens/landing_screen.dart';
import '../../features/auth/presentation/screens/login_screen.dart';
import '../../features/auth/presentation/screens/register_screen.dart';
import '../../features/dashboard/presentation/screens/dashboard_screen.dart';
import '../services/local_storage.dart';
import 'route_names.dart';

final appRouter = GoRouter(
  initialLocation: RouteNames.landing,
  debugLogDiagnostics: true,
  redirect: (context, state) {
    final loc    = state.matchedLocation;
    final hasClient = LocalStorage.clientNo != null;

    // Registration is always accessible
    if (loc == RouteNames.register) return null;

    // No client saved → always go to landing
    if (!hasClient && loc != RouteNames.landing) return RouteNames.landing;

    // Client saved → skip landing, go straight to login
    if (hasClient && loc == RouteNames.landing) return RouteNames.login;

    return null;
  },
  routes: [
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
    GoRoute(
      path: RouteNames.dashboard,
      builder: (context, state) => const DashboardScreen(),
    ),
  ],
);
