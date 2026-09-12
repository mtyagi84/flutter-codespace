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
  /// `Key('fieldKey')` on the target screen. Dispatches per value type:
  /// - `String`/`num` -> enters text into a TextFormField-like widget.
  /// - `_Select(optionText)` -> opens a dropdown/autocomplete and picks the
  ///   option matching `optionText`.
  /// - `DateTime` -> taps the field (opens a date picker) then selects that
  ///   date — actual picker interaction is screen-specific enough that this
  ///   currently just taps the field open; extend per-screen if a
  ///   screen's date picker needs bespoke handling.
  Future<void> fillForm(Map<String, dynamic> fieldValues) async {
    for (final entry in fieldValues.entries) {
      final finder = find.byKey(ValueKey(entry.key));
      expect(finder, findsOneWidget, reason: 'Missing Key("${entry.key}") on screen — add it before this field can be driven.');

      final value = entry.value;
      if (value is Select) {
        await tester.tap(finder);
        await tester.pumpAndSettle();
        final optionFinder = find.text(value.optionText).last;
        await tester.tap(optionFinder);
        await tester.pumpAndSettle();
      } else if (value is DateTime) {
        await tester.tap(finder);
        await tester.pumpAndSettle();
        // Screen-specific date-picker interaction goes here per screen as
        // this driver is extended — deliberately not generalized further
        // until a second screen's date picker proves what's actually common.
      } else {
        await tester.enterText(finder, value.toString());
        await tester.pumpAndSettle();
      }
    }
  }

  /// Taps a Save/Submit button by key and waits for the resulting
  /// confirmation, then reads back the generated document number from a
  /// widget carrying [docNoKey] (most entry screens surface this via
  /// ScreenHeaderMixin's title, e.g. Text(key: Key('header_doc_no'))).
  Future<String> submitAndCaptureDocNo({
    required String saveButtonKey,
    required String docNoKey,
  }) async {
    await tester.tap(find.byKey(ValueKey(saveButtonKey)));
    await tester.pumpAndSettle();
    final docNoWidget = tester.widget<Text>(find.byKey(ValueKey(docNoKey)));
    return docNoWidget.data ?? '';
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
