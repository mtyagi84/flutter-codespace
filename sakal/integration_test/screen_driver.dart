import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/core/router/app_router.dart';

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
class ScreenDriver {
  final WidgetTester tester;
  ScreenDriver(this.tester);

  /// Navigates via the app's own router (never a hand-typed route string —
  /// always pass a `RouteNames` constant), exercising the same
  /// navigation/permission path a real user hits.
  Future<void> navigateTo(String routeName) async {
    appRouter.go(routeName);
    await tester.pumpAndSettle();
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
      expect(outer, findsOneWidget, reason: 'Missing Key("${entry.key}") on screen — add it before this field can be driven.');
      final target = _resolveEditable(outer);

      final value = entry.value;
      if (value is Select) {
        await tester.tap(target);
        await tester.pumpAndSettle();
        final optionFinder = find.text(value.optionText).last;
        await tester.tap(optionFinder);
        await tester.pumpAndSettle();
      } else if (value is DateTime) {
        await tester.tap(target);
        await tester.pumpAndSettle();
        // Screen-specific date-picker interaction goes here per screen as
        // this driver is extended — deliberately not generalized further
        // until a second screen's date picker proves what's actually common.
      } else {
        await tester.enterText(target, value.toString());
        await tester.pumpAndSettle();
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
    await tester.pumpAndSettle();
  }

  /// Taps an Approve button by key — kept separate from submit since
  /// `canApprove` (ScreenPermissionMixin) gates it as a distinct action from
  /// `canAdd`/`canEdit` on many screens.
  Future<void> approve({String approveButtonKey = 'btn_approve'}) async {
    await tester.tap(find.byKey(ValueKey(approveButtonKey)));
    await tester.pumpAndSettle();
  }

  /// Asserts the current screen shows no error state — the "does this
  /// report/screen render at all" smoke check described in the plan,
  /// distinct from a full numeric report diff.
  void expectNoErrorState() {
    expect(find.textContaining('Unable to'), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsNothing);
  }
}

/// Marks a field value as "pick this option from a dropdown/autocomplete"
/// rather than "type this text" — pass `Select('Some Option')` in a
/// `fillForm` map instead of a plain String when the field is a picker.
class Select {
  final String optionText;
  const Select(this.optionText);
}
