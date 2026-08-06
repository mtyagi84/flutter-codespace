import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Data a screen supplies to the shared TopBar instead of building its own
/// separate title block as body content — see the "Screen header" mandatory
/// pattern in CLAUDE.md and design_system_guide.md §5.1.
@immutable
class ScreenHeaderInfo {
  final String title;
  final String? subtitle;
  final String? badgeText;
  final Color? badgeColor;

  /// An extra widget shown beside the subtitle/badge row — e.g. a
  /// per-document PendingSyncBadge. Kept as a raw widget slot (rather than
  /// another string field) since this one genuinely needs live widget
  /// behavior, not just styled text.
  final Widget? trailingBadge;

  /// Screen-specific trailing actions (e.g. Print) rendered in the shared
  /// TopBar's own action row — never a separately-rendered button in the
  /// body. Global, app-wide preferences (Theme, Density) do NOT belong
  /// here — they live in the avatar popup menu, the same place regardless
  /// of which screen is showing.
  final List<Widget> actions;

  const ScreenHeaderInfo({
    required this.title,
    this.subtitle,
    this.badgeText,
    this.badgeColor,
    this.trailingBadge,
    this.actions = const [],
  });
}

/// Read by TopBar to render the current screen's title/subtitle/badge/
/// actions. Set via [ScreenHeaderMixin] — never assign this directly from
/// a screen; the mixin handles the post-frame timing and the
/// push/pop-reveal refresh below.
final screenHeaderProvider = StateProvider<ScreenHeaderInfo?>((ref) => null);

/// Registered on GoRouter's own `navigatorObservers` (see app_router.dart)
/// so a screen using [ScreenHeaderMixin] can be told when it becomes
/// visible again after a screen pushed on top of it is popped — without
/// this, the provider would keep showing the popped screen's last header
/// instead of reverting, since a covered screen stays mounted (never
/// disposes, never rebuilds) while it's covered.
final routeObserver = RouteObserver<PageRoute<dynamic>>();

/// Mixin for any screen that wants its title/subtitle/badge/actions shown
/// in the shared TopBar. Override [buildScreenHeader]; call
/// [refreshScreenHeader] whenever screen state that affects the header
/// changes (e.g. a document finishes loading and now has a doc number/
/// status to show).
mixin ScreenHeaderMixin<T extends ConsumerStatefulWidget> on ConsumerState<T> implements RouteAware {
  ScreenHeaderInfo buildScreenHeader();

  void refreshScreenHeader() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(screenHeaderProvider.notifier).state = buildScreenHeader();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) routeObserver.subscribe(this, route);
    refreshScreenHeader();
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  // RouteAware — only didPopNext matters here (this screen becoming
  // visible again after whatever was pushed on top of it is popped); the
  // other three are no-ops but required by the interface.
  @override
  void didPush() {}
  @override
  void didPop() {}
  @override
  void didPushNext() {}
  @override
  void didPopNext() => refreshScreenHeader();
}
