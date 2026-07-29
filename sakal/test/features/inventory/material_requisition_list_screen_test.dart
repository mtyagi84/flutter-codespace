import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/features/inventory/data/models/material_requisition_model.dart';
import 'package:sakal/features/inventory/domain/repositories/material_requisition_repository.dart';
import 'package:sakal/features/inventory/presentation/providers/material_requisition_providers.dart';
import 'package:sakal/features/inventory/presentation/screens/material_requisition_list_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockMaterialRequisitionRepository extends Mock implements MaterialRequisitionRepository {}

void main() {
  late MockMaterialRequisitionRepository mockRepo;

  setUp(() {
    mockRepo = MockMaterialRequisitionRepository();
  });

  // Built fresh inside each test (never at the top of main()) — mockRepo is
  // a `late` variable only assigned once setUp() runs before each test, so
  // referencing it while main() itself is still executing synchronously
  // throws LateError. SyncEngine(null) is a real instance (no Drift db),
  // which degrades every read to an empty/zero result — exactly "nothing
  // pending", with no need to mock it.
  List<Override> overrides() => [
        materialRequisitionRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  testWidgets('shows a loading indicator before the first page resolves', (tester) async {
    when(() => mockRepo.listRequisitions(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) => Completer<List<MaterialRequisitionHeader>>().future);

    await pumpApp(tester, const MaterialRequisitionListScreen(), overrides: overrides(), session: testSession());
    await tester.pump(); // let initState's postFrameCallback fire and _load() start

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders a card per requisition once the page loads', (tester) async {
    when(() => mockRepo.listRequisitions(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => [
          MaterialRequisitionHeader.fromJson(const {
            'requisition_no': 'MREQ-001',
            'requisition_date': '2026-07-01',
            'requested_by': 'Alice',
            'reason': 'Office Supplies',
            'location_id': 'loc-001',
            'location': {'location_name': 'Main Store'},
            'status': 'DRAFT',
          }),
          MaterialRequisitionHeader.fromJson(const {
            'requisition_no': 'MREQ-002',
            'requisition_date': '2026-07-02',
            'requested_by': '',
            'reason': '',
            'location_id': 'loc-002',
            'status': 'APPROVED',
          }),
        ]);

    await pumpApp(tester, const MaterialRequisitionListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('MREQ-001'), findsOneWidget);
    expect(find.text('MREQ-002'), findsOneWidget);
    expect(find.text('Office Supplies · 01 Jul 2026'), findsOneWidget);
    expect(find.text('Alice · Main Store'), findsOneWidget);
    // The second requisition has empty reason/requestedBy/locationName — the
    // card renders each as an em-dash placeholder rather than blank.
    expect(find.text('— · 02 Jul 2026'), findsOneWidget);
    expect(find.text('— · —'), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);
    expect(find.text('Approved'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows the empty state when the page loads with zero requisitions', (tester) async {
    when(() => mockRepo.listRequisitions(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => []);

    await pumpApp(tester, const MaterialRequisitionListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('No requisitions found'), findsOneWidget);
  });

  testWidgets('shows the interpolated error message when the repository throws', (tester) async {
    when(() => mockRepo.listRequisitions(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenThrow(Exception('connection refused'));

    await pumpApp(tester, const MaterialRequisitionListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    // NOTE: unlike Finance's ErrorPresenter-based screens, this screen's own
    // _load() catch block interpolates the raw exception directly
    // (`'Could not load requisitions: $e'`) — asserting the literal text
    // actually shown, not a friendly ErrorPresenter message.
    expect(find.text('Could not load requisitions: Exception: connection refused'), findsOneWidget);
  });
}
