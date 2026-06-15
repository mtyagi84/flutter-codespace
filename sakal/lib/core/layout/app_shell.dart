import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/session_provider.dart';
import '../router/route_names.dart';
import '../theme/app_colors.dart';
import 'sidebar.dart';
import 'top_bar.dart';

class AppShell extends ConsumerWidget {
  final Widget child;

  const AppShell({required this.child, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session   = ref.watch(sessionProvider);
    final collapsed = ref.watch(sidebarCollapsedProvider);

    if (session == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        context.go(RouteNames.login);
      });
      return const Scaffold(
        backgroundColor: AppColors.primary,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    final double sidebarW = collapsed ? 56.0 : 240.0;
    // Compute content width from MediaQuery (build time) rather than relying
    // on Expanded's flex algorithm (layout time). GoRouter's Overlay passes
    // loose/unbounded constraints to child screens during Codespace resize
    // events; a hard MediaQuery-derived SizedBox prevents that entirely.
    final double contentW =
        (MediaQuery.sizeOf(context).width - sidebarW - 1.0).clamp(0.0, double.infinity);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: const TopBar(),
      body: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            width: sidebarW,
            child: const Sidebar(),
          ),
          const VerticalDivider(
              width: 1, thickness: 1, color: AppColors.border),
          SizedBox(width: contentW, child: child),
        ],
      ),
    );
  }
}
