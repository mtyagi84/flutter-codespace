import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../utils/app_logger.dart';

/// Data a screen supplies to the shared TopBar instead of building its own
/// separate title block as body content — see the "Screen header" mandatory
/// pattern in CLAUDE.md and design_system_guide.md §5.1.
@immutable
class ScreenHeaderInfo {
  final String title;
  final String? subtitle;

  /// Static, descriptive "what this screen is for" prose (e.g. "Edit your
  /// company profile, contact details and tax information.") — rendered as
  /// a small tappable help icon next to the title instead of a permanent
  /// subtitle line, since it never changes and doesn't need to occupy
  /// screen-header space at all times. Use [subtitle] instead for anything
  /// that reflects live state (Draft/Approved, a source-document
  /// reference, a live count) — that keeps reflecting real information the
  /// user needs to see at a glance, not a description of the screen itself.
  final String? helpText;
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
    this.helpText,
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

/// Tracks which [ScreenHeaderMixin] instance most recently posted to
/// [screenHeaderProvider] — module-level, not a Riverpod provider, since
/// it only ever needs to be compared, never watched/rebuilt-on. See the
/// dispose()/ownership note below for why this exists: a screen that's
/// merely covered by a pushed route stays mounted (never disposes) while
/// covered, so a naive "always clear on dispose" would let a *later*-
/// disposing covered screen wrongly wipe out whatever the *currently
/// active* screen already posted.
Object? _screenHeaderOwner;

/// Mixin for any screen that wants its title/subtitle/badge/actions shown
/// in the shared TopBar. Override [buildScreenHeader]; call
/// [refreshScreenHeader] whenever screen state that affects the header
/// changes (e.g. a document finishes loading and now has a doc number/
/// status to show).
mixin ScreenHeaderMixin<T extends ConsumerStatefulWidget> on ConsumerState<T> implements RouteAware {
  ScreenHeaderInfo buildScreenHeader();

  // Cached once rather than re-read via `ref` at dispose time — `ref` is
  // not safe to use once a widget is mid-disposal, but a plain
  // StateController object obtained earlier stays safely usable for the
  // app's lifetime (the provider itself never gets disposed).
  StateController<ScreenHeaderInfo?>? _headerController;

  void refreshScreenHeader() {
    _headerController ??= ref.read(screenHeaderProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        AppLogger.info('ScreenHeader', 'refreshScreenHeader SKIPPED (unmounted) for $runtimeType');
        return;
      }
      _screenHeaderOwner = this;
      final info = buildScreenHeader();
      AppLogger.info('ScreenHeader', 'CLAIM "${info.title}" by $runtimeType');
      _headerController!.state = info;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _headerController ??= ref.read(screenHeaderProvider.notifier);
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      routeObserver.subscribe(this, route);
      AppLogger.info('ScreenHeader', 'didChangeDependencies: subscribed $runtimeType to route ${route.settings.name ?? route.hashCode}');
    }
    refreshScreenHeader();
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    // Only clear if this screen is still the current owner — real bug,
    // fixed 2026-08-06: an earlier version of this mixin never cleared on
    // dispose at all (to dodge exactly the race described above), which
    // left the TopBar stuck showing a screen's title forever after
    // navigating away (via context.go(), a genuine dispose, not a
    // push/pop cover) to a screen that doesn't use this mixin. The
    // ownership check makes both cases safe at once — see
    // design_system_guide.md §5.1 for the full trace of both scenarios.
    if (identical(_screenHeaderOwner, this)) {
      AppLogger.info('ScreenHeader', 'CLEAR (dispose, still owner) by $runtimeType');
      _screenHeaderOwner = null;
      _headerController?.state = null;
    } else {
      AppLogger.info('ScreenHeader', 'dispose, NOT owner ($runtimeType) — leaving header as-is');
    }
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
  void didPopNext() {
    AppLogger.info('ScreenHeader', 'didPopNext fired for $runtimeType');
    refreshScreenHeader();
  }
}
