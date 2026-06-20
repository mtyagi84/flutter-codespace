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
    // SelectionArea must live inside Scaffold (which is inside Navigator → Overlay).
    // Wrapping here covers every page rendered through AppShell on both layouts.
    final pageContent = SelectionArea(child: widget.child);

    if (Responsive.isMobile(context)) {
      return Scaffold(
        key: _scaffoldKey,
        backgroundColor: AppColors.background,
        appBar: TopBar(scaffoldKey: _scaffoldKey),
        drawer: const Drawer(child: Sidebar()),
        body: Column(
          children: [
            if (offline) const OfflineBanner(),
            Expanded(child: pageContent),
          ],
        ),
      );
    }

    final double sidebarW = collapsed ? 56.0 : 240.0;
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
                Expanded(child: pageContent),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
