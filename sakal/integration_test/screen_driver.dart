import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/core/router/app_router.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Drives the real app's widget tree via `integration_test` — never the DOM
/// (Flutter Web renders to canvas/WebGL, so DOM-based tools like Playwright
/// are brittle here; see the approved E2E test automation plan for why
/// `integration_test` was chosen instead).
///
/// Every list/entry screen in this app already uses `ScreenPermissionMixin`
/// keyed by its own route path (`screenName`) — this driver leans on that
/// same uniformity: a test case becomes "a field-value map + expected
/// assertions," not a bespoke widget-tree-walking test per screen.
///
/// REQUIRES widget `Key`s on the screen being driven — see this folder's
/// README.md for the naming convention. A screen with no keys yet cannot be
/// driven reliably; that's real, incremental retrofit work, not a gap in
/// this class.
///
/// Every `pumpAndSettle()` call below passes an explicit `timeout:` --
/// confirmed live 2026-09-13 that the bare, unbounded form
/// (`pumpAndSettle()` with no timeout) hangs indefinitely against this app:
/// something in the widget tree never fully settles (a subtle ongoing
/// animation somewhere, not yet root-caused further), so a driven test run
/// sat idle past a 15-minute outer `timeout` with 0% CPU usage -- not
/// "slow," genuinely stuck forever. `pumpAndSettle(timeout: ...)` instead
/// throws a catchable, informative `FlutterError` once the bound is hit.
/// Never add a new bare `pumpAndSettle()` call to this file.
class ScreenDriver {
  final WidgetTester tester;
  ScreenDriver(this.tester);

  /// Logs in as the QA tenant, tolerating all three real login-screen states
  /// — never assume only the full 3-field form exists. The browser profile
  /// used by a local `flutter drive` run persists `LocalStorage.clientNo`
  /// (and the JWT, via `flutter_secure_storage`'s web backend) ACROSS
  /// separate runs, same as it would for a real returning user's browser —
  /// confirmed live 2026-09-13 (a first run showed the full Client
  /// ID/Username/Password form; every run after showed the "quick login"
  /// state — client_no already saved, only Username/Password fields exist).
  /// A test that only ever fills the 3-field form (gated by `login_client_no`
  /// being present) silently no-ops on every run after the first, then fails
  /// confusingly downstream when `navigateTo` lands back on `/login`. This
  /// method fills whichever fields actually exist, using `btn_login`'s own
  /// presence as the single reliable "still need to log in" signal, and
  /// treats its absence after pumping the app as "already authenticated,
  /// nothing to do" (a real state this app supports but this test suite
  /// doesn't currently exercise, since every test calls `resetQaTenant`
  /// first via a fresh `BackendVerifier`, not the driven UI session).
  Future<void> login() async {
    // pumpAndSettle does NOT reliably wait out a bare async gap with no
    // continuous frame scheduling (e.g. an async initial-route/session
    // check before the router picks a screen) — confirmed live 2026-09-13:
    // it returned after its full 20s timeout with the login screen still
    // not yet rendered, making `btn_login` absent look identical to "already
    // authenticated." Poll explicitly for either signal instead of trusting
    // a single pumpAndSettle call.
    var loginVisible = false;
    for (var i = 0; i < 100 && !loginVisible; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      loginVisible = tester.any(find.byKey(const Key('btn_login')));
    }
    if (!loginVisible) {
      return; // already authenticated — nothing to do
    }
    // Extra settle: LoginScreen's own initState kicks off a real async
    // OfflineSessionCache lookup (_checkCache) that can still be in flight
    // the instant btn_login first appears — confirmed live 2026-09-13 as a
    // "Bad state: No element" race inside enterText immediately after this
    // poll, on a field that WAS present one line earlier. flutter drive runs
    // on a real wall clock with real I/O, unlike flutter test's synthetic
    // clock, so this class of race is real, not hypothetical.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    if (tester.any(find.byKey(const Key('login_client_no')))) {
      await _enterTextResilient(const Key('login_client_no'), TestTenantConfig.clientNo);
    }
    await _enterTextResilient(const Key('login_username'), TestTenantConfig.username);
    await _enterTextResilient(const Key('login_password'), TestTenantConfig.password);
    await tester.tap(find.byKey(const Key('btn_login')));

    // Same reasoning as the poll above — login here is two sequential real
    // network round trips (fn_login + fn_get_user_menu), and pumpAndSettle
    // is not a reliable substitute for actually waiting them out.
    var stillOnLogin = true;
    for (var i = 0; i < 150 && stillOnLogin; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      stillOnLogin = tester.any(find.byKey(const Key('btn_login')));
    }
    if (stillOnLogin) {
      fail('Still on login screen after submitting credentials — login did not succeed.\n'
          'Visible text: ${visibleText()}');
    }
  }

  /// `tester.enterText` occasionally throws `StateError: Bad state: No
  /// element` on a field confirmed present one statement earlier — a real
  /// wall-clock rebuild race (see `login()`'s own comment), not a bug in the
  /// target screen. One short settle + one retry is standard, proportionate
  /// resilience for a real-device/real-I/O test; a SECOND failure is a real
  /// problem and is allowed to propagate.
  Future<void> _enterTextResilient(Key key, String value) async {
    try {
      await tester.enterText(find.byKey(key), value);
    } on StateError {
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byKey(key), value);
    }
  }

  /// Navigates via the app's own router (never a hand-typed route string —
  /// always pass a `RouteNames` constant), exercising the same
  /// navigation/permission path a real user hits.
  Future<void> navigateTo(String routeName) async {
    appRouter.go(routeName);
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 15));
    // A freshly-navigated screen's own async data load (pickers' options
    // lists, etc.) is the same pumpAndSettle-vs-real-async-gap class of
    // issue as login() above — a fixed real-time pump buffer here is a
    // general safety net every future screen benefits from, since this
    // method has no specific key to poll for.
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  /// Fills a form from a field-key -> value map. Each key must match a
  /// `Key('fieldKey')` on the target screen — either directly on a
  /// `TextFormField`, or on a `KeyedSubtree` wrapping a picker (e.g. a
  /// `SakalAutocomplete`-based field, which already carries its OWN
  /// rebuild-identity key for a documented, unrelated reason — see this
  /// folder's README — so a test hook wraps it rather than replacing it).
  /// [_resolveEditable] finds the actual interactive descendant either way.
  /// Dispatches per value type:
  /// - `String`/`num` -> enters text.
  /// - `Select(optionText)` -> taps to open, picks the matching option.
  /// - `DateTime` -> taps the field open — actual picker interaction is
  ///   screen-specific enough that this currently just opens it; extend
  ///   per-screen if a screen's date picker needs bespoke handling.
  Future<void> fillForm(Map<String, dynamic> fieldValues) async {
    for (final entry in fieldValues.entries) {
      final outer = find.byKey(ValueKey(entry.key));
      if (tester.any(outer) == false) {
        fail('Missing Key("${entry.key}") on screen — add it before this field can be driven.\n'
            'Visible text on screen right now (to tell "wrong screen" from "wrong key name"):\n${visibleText()}');
      }
      final target = _resolveEditable(outer);

      final value = entry.value;
      if (value is Select) {
        await tester.tap(target);
        await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 15));
        final optionFinder = find.text(value.optionText).last;
        await tester.tap(optionFinder);
        await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 15));
      } else if (value is DateTime) {
        await tester.tap(target);
        await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 15));
        // Screen-specific date-picker interaction goes here per screen as
        // this driver is extended — deliberately not generalized further
        // until a second screen's date picker proves what's actually common.
      } else {
        await tester.enterText(target, value.toString());
        await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 15));
      }
    }
  }

  /// A `Key('fieldKey')` may sit on a non-editable wrapper (`KeyedSubtree`)
  /// around a picker rather than directly on the editable widget itself —
  /// resolve to the actual `TextFormField`/`TextField` descendant when so.
  Finder _resolveEditable(Finder outer) {
    final textFormField = find.descendant(of: outer, matching: find.byType(TextFormField));
    if (tester.any(textFormField)) return textFormField;
    final textField = find.descendant(of: outer, matching: find.byType(TextField));
    if (tester.any(textField)) return textField;
    return outer;
  }

  /// Taps a Save/Submit button by key and waits for the resulting
  /// confirmation. Deliberately does NOT try to scrape the generated
  /// document number back out of the UI (e.g. a header title string like
  /// "Goods Receipt · GRN-123") — per the plan, backend verification is the
  /// authoritative source of truth anyway, so a test looks up the newly
  /// created row directly via `BackendVerifier` after calling this.
  Future<void> submit({String saveButtonKey = 'btn_save'}) async {
    await tester.tap(find.byKey(ValueKey(saveButtonKey)));
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 15));
  }

  /// Taps an Approve button by key — kept separate from submit since
  /// `canApprove` (ScreenPermissionMixin) gates it as a distinct action from
  /// `canAdd`/`canEdit` on many screens.
  Future<void> approve({String approveButtonKey = 'btn_approve'}) async {
    await tester.tap(find.byKey(ValueKey(approveButtonKey)));
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 15));
  }

  /// Asserts the current screen shows no error state — the "does this
  /// report/screen render at all" smoke check described in the plan,
  /// distinct from a full numeric report diff.
  void expectNoErrorState() {
    expect(find.textContaining('Unable to'), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsNothing);
  }

  /// Dumps every visible Text widget's string — a cheap diagnostic for
  /// "which screen am I actually on" when a key-driven action fails. Added
  /// 2026-09-13 after a Missing-Key failure gave no way to tell "wrong
  /// screen (nav/permission/login issue)" from "wrong key name" without
  /// re-running under a debugger.
  String visibleText() {
    final texts = <String>{};
    for (final element in find.byType(Text).evaluate()) {
      final widget = element.widget;
      if (widget is Text && widget.data != null && widget.data!.trim().isNotEmpty) {
        texts.add(widget.data!.trim());
      }
    }
    return texts.isEmpty ? '(no Text widgets found)' : texts.join(' | ');
  }
}

/// Marks a field value as "pick this option from a dropdown/autocomplete"
/// rather than "type this text" — pass `Select('Some Option')` in a
/// `fillForm` map instead of a plain String when the field is a picker.
class Select {
  final String optionText;
  const Select(this.optionText);
}
