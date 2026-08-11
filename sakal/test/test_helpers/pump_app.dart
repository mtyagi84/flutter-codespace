import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/core/layout/screen_header.dart';
import 'package:sakal/core/providers/session_provider.dart';

/// Shared widget-test harness — every real screen in this app needs at
/// least [sessionProvider] populated (most call `ref.read(sessionProvider)!`
/// directly, which null-check-throws otherwise) and lives inside a
/// MaterialApp/Scaffold. `menuProvider` is deliberately left at its default
/// empty-list value unless a test overrides it — ScreenPermissionMixin
/// already treats "screen not found in menu" as canAdd/canEdit=true,
/// canApprove=false, which is a reasonable default for a plain render test.
///
/// Does NOT set a custom test surface size — the flutter_test default
/// (~800x600 logical) is below the 1024px desktop breakpoint, so
/// SakalAdaptiveList-based screens render their mobile/card branch, which
/// avoids needing to also override themePresetProvider (only the desktop
/// table branch reads it). Tests that specifically need the desktop table
/// branch should set `tester.view.physicalSize` themselves.
Future<void> pumpApp(
  WidgetTester tester,
  Widget child, {
  List<Override> overrides = const [],
  UserSession? session,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (session != null) sessionProvider.overrideWith((ref) => session),
        ...overrides,
      ],
      // Real gap found live 2026-08-11: the production TopBar renders
      // ScreenHeaderInfo.actions (Save/Approve/Print/... on desktop, per
      // the "Screen header" mandatory pattern) inside its own AppBar —
      // this bare Scaffold never did, so any screen that moved a button
      // into header.actions (rather than the body) became untappable/
      // unfindable in every widget test, even though it renders correctly
      // in the real app. A minimal Consumer + AppBar here, showing exactly
      // header.actions, closes that gap without needing the full TopBar's
      // styling/menu/avatar machinery — tests only need the buttons to
      // exist and be tappable, not to look identical to production chrome.
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) {
            final header = ref.watch(screenHeaderProvider);
            return Scaffold(
              appBar: (header != null && header.actions.isNotEmpty)
                  ? AppBar(title: Text(header.title), actions: header.actions)
                  : null,
              body: child,
            );
          },
        ),
      ),
    ),
  );
}

/// A reasonable default session for tests that don't care about its exact
/// field values — only that `ref.read(sessionProvider)!` doesn't null-check.
UserSession testSession({
  bool offlineMode = false,
  String? locationId = 'loc-001',
}) =>
    UserSession(
      userId: 'user-001',
      clientId: 'client-001',
      clientNo: 'CL-001',
      companyId: 'company-001',
      companyName: 'Test Company',
      locationId: locationId,
      fullName: 'Test User',
      username: 'testuser',
      offlineMode: offlineMode,
    );
