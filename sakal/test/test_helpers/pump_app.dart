import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
      child: MaterialApp(home: Scaffold(body: child)),
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
