import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/session_provider.dart';
import '../router/route_names.dart';
import '../theme/app_colors.dart';
import '../utils/responsive.dart';
import '../widgets/offline_banner.dart';
import 'sidebar.dart';
import 'top_bar.dart';

class AppShell extends ConsumerStatefulWidget {
  final Widget child;

  const AppShell({required this.child, super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {
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

    final offline = session.offlineMode;

    if (Responsive.isMobile(context)) {
      return Scaffold(
        key: _scaffoldKey,
        backgroundColor: AppColors.background,
        appBar: TopBar(scaffoldKey: _scaffoldKey),
        drawer: const Drawer(child: Sidebar()),
        body: Column(
          children: [
            if (offline) const OfflineBanner(),
            Expanded(child: widget.child),
          ],
        ),
      );
    }

    // Tablet zone (600-1024px, Responsive.isTablet) forces the collapsed
    // (icon-only) sidebar regardless of the user's own manual toggle --
    // real overflow/cramping was caught live at 739px width with a full
    // 240px sidebar leaving barely 498px for content, not nearly enough
    // for a data table with several columns. True desktop (>=1024px)
    // still respects whatever the user picked. This is the ONE place
    // AppShell itself widens beyond a plain isMobile check; individual
    // screens don't each need their own tablet-width handling as long as
    // they're already isMobile-aware, since this alone recovers most of
    // the missing width.
    final bool effectiveCollapsed = Responsive.isTablet(context) ? true : collapsed;
    final double sidebarW = effectiveCollapsed ? 56.0 : 240.0;
    final double contentW =
        (MediaQuery.sizeOf(context).width - sidebarW - 1.0).clamp(0.0, double.infinity);

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: AppColors.background,
      appBar: TopBar(scaffoldKey: _scaffoldKey),
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
          SizedBox(
            width: contentW,
            child: Column(
              children: [
                if (offline) const OfflineBanner(),
                Expanded(child: widget.child),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
