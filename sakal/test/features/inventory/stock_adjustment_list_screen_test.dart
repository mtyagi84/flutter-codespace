import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/features/inventory/data/models/stock_adjustment_model.dart';
import 'package:sakal/features/inventory/domain/repositories/stock_adjustment_repository.dart';
import 'package:sakal/features/inventory/presentation/providers/stock_adjustment_providers.dart';
import 'package:sakal/features/inventory/presentation/screens/stock_adjustment_list_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockStockAdjustmentRepository extends Mock implements StockAdjustmentRepository {}

void main() {
  late MockStockAdjustmentRepository mockRepo;

  setUp(() {
    mockRepo = MockStockAdjustmentRepository();
  });

  List<Override> overrides() => [
        stockAdjustmentRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  testWidgets('shows a loading indicator before the first page resolves', (tester) async {
    when(() => mockRepo.listAdjustments(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) => Completer<List<StockAdjustmentHeader>>().future);

    await pumpApp(tester, const StockAdjustmentListScreen(), overrides: overrides(), session: testSession());
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders a card per adjustment once the page loads', (tester) async {
    when(() => mockRepo.listAdjustments(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => [
          StockAdjustmentHeader.fromJson(const {
            'adjustment_no': 'ADJ-001',
            'adjustment_date': '2026-07-11',
            'location_id': 'loc-001',
            'location': {'location_name': 'Main Store'},
            'reason_id': 'reason-001',
            'reason': {'description': 'Damage'},
            'status': 'DRAFT',
          }),
          StockAdjustmentHeader.fromJson(const {
            'adjustment_no': 'ADJ-002',
            'adjustment_date': '2026-07-12',
            'location_id': 'loc-002',
            'reason_id': 'reason-002',
            'status': 'APPROVED',
          }),
        ]);

    await pumpApp(tester, const StockAdjustmentListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('ADJ-001'), findsOneWidget);
    expect(find.text('ADJ-002'), findsOneWidget);
    expect(find.text('11 Jul 2026'), findsOneWidget);
    expect(find.text('12 Jul 2026'), findsOneWidget);
    expect(find.text('Main Store'), findsOneWidget);
    expect(find.text('Damage'), findsOneWidget);
    // Second adjustment has both locationName and reasonLabel empty —
    // rendered as two separate em-dash placeholders.
    expect(find.text('—'), findsNWidgets(2));
    expect(find.text('Draft'), findsOneWidget);
    expect(find.text('Approved'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows the empty state when the page loads with zero adjustments', (tester) async {
    when(() => mockRepo.listAdjustments(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => []);

    await pumpApp(tester, const StockAdjustmentListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('No stock adjustments found'), findsOneWidget);
  });

  testWidgets('shows the interpolated error message when the repository throws', (tester) async {
    when(() => mockRepo.listAdjustments(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenThrow(Exception('connection refused'));

    await pumpApp(tester, const StockAdjustmentListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    // This screen's own _load() catch block interpolates the raw exception
    // directly (`'Could not load stock adjustments: $e'`) — no ErrorPresenter.
    expect(find.text('Could not load stock adjustments: Exception: connection refused'), findsOneWidget);
  });
}
