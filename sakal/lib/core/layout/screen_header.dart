import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../utils/app_logger.dart';

/// Delay before [ScreenHeaderMixin.dispose] clears an unclaimed header —
/// see that method's own comment for why 400ms was chosen in production
/// (giving a newly-navigated-to screen time to claim ownership first).
/// Widget tests override this to a near-zero value via
/// `test/flutter_test_config.dart` — a real, pending `Future.delayed`
/// left outstanding when a test ends fails that test ("pending timer"),
/// and 604 widget tests across every screen using this mixin all
/// disposing one at test teardown made this a real, live regression
/// (247/604 failing) the day this was introduced, not a hypothetical one.
/// Production code must never set this itself.
@visibleForTesting
Duration screenHeaderClearDelay = const Duration(milliseconds: 400);

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
    // Deferred via a microtask, not addPostFrameCallback — real bug found
    // live 2026-08-16 via /dev/logs: "Tried to modify a provider while the
    // widget tree was building" was being thrown from inside this exact
    // callback during a route transition (a Navigator page-list diff can
    // still have BuildOwner.building==true during some of its own internal
    // callback-phase work, particularly around route-transition teardown/
    // rebuild). When that throw happens mid-notification, the provider's
    // OWN `.state` field may already be updated but listeners (TopBar's
    // `ref.watch`) never get properly notified — the TopBar keeps
    // rendering whatever it last successfully rendered, i.e. a stale
    // title, exactly the symptom reported. A microtask runs in a genuinely
    // separate Dart event-loop turn, never inside Flutter's own frame
    // pipeline, so it can't collide with BuildOwner's building flag.
    Future.microtask(() {
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
    //
    // A same-frame microtask was tried first (2026-08-16) and made things
    // WORSE live: it cleared the header to blank (company-name fallback)
    // instead of leaving it stale — meaning this dispose()'s clear-
    // microtask was in practice running AFTER the newly-navigated screen's
    // own claim-microtask, wiping it out, not before it as the frame-
    // lifecycle analysis predicted (GoRouter's declarative Navigator
    // page-list diffing + route-transition-animation teardown doesn't
    // reliably keep dispose() inside the SAME synchronous frame as the
    // revealed screen's build() — it can run one or more frames later,
    // after the transition animation finishes, by which point the other
    // screen has already claimed). A short, deliberate delay is the
    // robust fix: give whatever screen the user actually navigated to
    // generous time to claim ownership first — a real claim (another
    // screen's own build()/didChangeDependencies()) happens within
    // milliseconds, while this only fires at all if genuinely NOTHING
    // else ever claims (e.g. navigating to a screen that doesn't use this
    // mixin), which is the one case this clear exists for in the first
    // place.
    final controller = _headerController;
    final owner = this;
    void doClear() {
      if (identical(_screenHeaderOwner, owner)) {
        AppLogger.info('ScreenHeader', 'CLEAR (dispose, still owner) by $runtimeType');
        _screenHeaderOwner = null;
        controller?.state = null;
      } else {
        AppLogger.info('ScreenHeader', 'dispose, NOT owner ($runtimeType) — leaving header as-is');
      }
    }
    // Duration.zero is a deliberate escape hatch, used only by
    // test/flutter_test_config.dart: widget tests run inside flutter_test's
    // FakeAsync zone, where virtual time only advances when a test
    // explicitly pumps for a duration — ANY positive Future.delayed
    // (even 1ms) still counts as a "pending timer" and fails the test
    // unless that exact test's own final pump happens to advance past it.
    // Shortening the duration alone (tried first) does not fix this — the
    // only reliable fix is to never create a Timer at all in test mode.
    // Calling doClear() synchronously here is safe specifically because
    // the race this delay protects against (a real GoRouter page
    // transition, spanning multiple frames) does not exist in an isolated
    // widget test's teardown.
    if (screenHeaderClearDelay == Duration.zero) {
      doClear();
    } else {
      Future.delayed(screenHeaderClearDelay, doClear);
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
