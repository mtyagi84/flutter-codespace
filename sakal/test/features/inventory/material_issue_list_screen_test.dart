import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/features/inventory/data/models/material_issue_model.dart';
import 'package:sakal/features/inventory/domain/repositories/material_issue_repository.dart';
import 'package:sakal/features/inventory/presentation/providers/material_issue_providers.dart';
import 'package:sakal/features/inventory/presentation/screens/material_issue_list_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockMaterialIssueRepository extends Mock implements MaterialIssueRepository {}

void main() {
  late MockMaterialIssueRepository mockRepo;

  setUp(() {
    mockRepo = MockMaterialIssueRepository();
  });

  List<Override> overrides() => [
        materialIssueRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  testWidgets('shows a loading indicator before the first page resolves', (tester) async {
    when(() => mockRepo.listIssues(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) => Completer<List<MaterialIssueHeader>>().future);

    await pumpApp(tester, const MaterialIssueListScreen(), overrides: overrides(), session: testSession());
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders a card per issue once the page loads', (tester) async {
    when(() => mockRepo.listIssues(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => [
          MaterialIssueHeader.fromJson(const {
            'issue_no': 'MISS-001',
            'issue_date': '2026-07-03',
            'location_id': 'loc-001',
            'location': {'location_name': 'Warehouse A'},
            'status': 'DRAFT',
          }),
          MaterialIssueHeader.fromJson(const {
            'issue_no': 'MISS-002',
            'issue_date': '2026-07-04',
            'location_id': 'loc-002',
            'status': 'APPROVED',
          }),
        ]);

    await pumpApp(tester, const MaterialIssueListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('MISS-001'), findsOneWidget);
    expect(find.text('MISS-002'), findsOneWidget);
    expect(find.text('03 Jul 2026'), findsOneWidget);
    expect(find.text('04 Jul 2026'), findsOneWidget);
    expect(find.text('Warehouse A'), findsOneWidget);
    // Second issue has an empty locationName — rendered as an em-dash.
    expect(find.text('—'), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);
    expect(find.text('Approved'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows the empty state when the page loads with zero issues', (tester) async {
    when(() => mockRepo.listIssues(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => []);

    await pumpApp(tester, const MaterialIssueListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('No material issues found'), findsOneWidget);
  });

  testWidgets('shows the interpolated error message when the repository throws', (tester) async {
    when(() => mockRepo.listIssues(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenThrow(Exception('connection refused'));

    await pumpApp(tester, const MaterialIssueListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    // This screen's own _load() catch block interpolates the raw exception
    // directly (`'Could not load material issues: $e'`) — no ErrorPresenter.
    expect(find.text('Could not load material issues: Exception: connection refused'), findsOneWidget);
  });
}
