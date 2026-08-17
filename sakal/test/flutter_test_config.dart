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
/// Shortening the delay to near-zero here (rather than adding an explicit
/// long pump to every affected test) means most tests' own EXISTING final
/// pump (already non-zero in this codebase's convention — see the
/// "Widget-test DioClient gotchas" pattern) flushes it for free, with zero
/// per-test changes needed.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  screenHeaderClearDelay = const Duration(milliseconds: 1);
  await testMain();
}
