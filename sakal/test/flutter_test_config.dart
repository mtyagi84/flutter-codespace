import 'dart:async';

import 'package:sakal/core/layout/screen_header.dart';

/// Flutter's test runner auto-discovers a `flutter_test_config.dart` at the
/// root of `test/` and wraps EVERY test file under it (recursively) with
/// this `testExecutable` — no per-file import needed.
///
/// Real regression, found live 2026-08-19: `ScreenHeaderMixin.dispose()`
/// schedules a genuine `Future.delayed(400ms)` in production (see that
/// file's own comment for why — it fixes a real TopBar-stuck-title bug).
/// Every widget test that mounts a screen using this mixin implicitly
/// disposes it at test teardown, leaving that 400ms `Future.delayed`
/// pending when the test function returns — `flutter_test` fails any test
/// that ends with a timer still outstanding ("Pending timers"). Since the
/// mixin is used by nearly every entry/list screen by now, this took down
/// 247 of 604 tests app-wide the same session the delay was introduced,
/// spread evenly across screens rather than concentrated in one module —
/// the tell that it's a shared-infrastructure issue, not a one-off bug in
/// any particular screen.
///
/// First attempt: shortened the delay to 1ms here. That was insufficient —
/// confirmed live via a failing test's own stack trace, which showed the
/// scheduled Timer's duration WAS correctly 1ms, yet the test still failed
/// with "Pending timers". Root cause: `flutter_test` runs each test inside
/// `fake_async`'s `FakeAsync` zone, where virtual time only advances when
/// the test explicitly pumps for a duration — a bare `tester.pump()` (zero
/// duration) never advances the fake clock, so even a 1ms `Future.delayed`
/// remains "pending" at teardown unless that exact test happens to pump
/// past it. Shortening the duration doesn't change that; only avoiding the
/// Timer entirely does.
///
/// `Duration.zero` is a deliberate signal `ScreenHeaderMixin.dispose()`
/// checks for (see that method's own comment) to skip `Future.delayed`
/// entirely in test mode and clear the header synchronously instead — no
/// Timer is ever created, so there is nothing left pending at teardown,
/// regardless of what any individual test's own pump calls do.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  screenHeaderClearDelay = Duration.zero;
  await testMain();
}
