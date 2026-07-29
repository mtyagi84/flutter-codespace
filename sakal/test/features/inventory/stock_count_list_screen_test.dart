import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/features/inventory/data/models/stock_count_model.dart';
import 'package:sakal/features/inventory/domain/repositories/stock_count_repository.dart';
import 'package:sakal/features/inventory/presentation/providers/stock_count_providers.dart';
import 'package:sakal/features/inventory/presentation/screens/stock_count_list_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockStockCountRepository extends Mock implements StockCountRepository {}

void main() {
  late MockStockCountRepository mockRepo;

  setUp(() {
    mockRepo = MockStockCountRepository();
  });

  List<Override> overrides() => [
        stockCountRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  testWidgets('shows a loading indicator before the first page resolves', (tester) async {
    when(() => mockRepo.listStockCounts(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) => Completer<List<StockCountHeader>>().future);

    await pumpApp(tester, const StockCountListScreen(), overrides: overrides(), session: testSession());
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders a card per count once the page loads', (tester) async {
    when(() => mockRepo.listStockCounts(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => [
          StockCountHeader.fromJson(const {
            'count_no': 'CNT-001',
            'count_date': '2026-07-15',
            'location_id': 'loc-001',
            'location': {'location_name': 'Main Store'},
            'status': 'DRAFT',
          }),
          StockCountHeader.fromJson(const {
            'count_no': 'CNT-002',
            'count_date': '2026-07-16',
            'location_id': 'loc-002',
            'status': 'SUBMITTED',
          }),
        ]);

    await pumpApp(tester, const StockCountListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('CNT-001'), findsOneWidget);
    expect(find.text('CNT-002'), findsOneWidget);
    expect(find.text('15 Jul 2026'), findsOneWidget);
    expect(find.text('16 Jul 2026'), findsOneWidget);
    expect(find.text('Main Store'), findsOneWidget);
    // Second count has an empty locationName — rendered as an em-dash.
    expect(find.text('—'), findsOneWidget);
    // This screen's own _statusBadge shows the raw status code.
    expect(find.text('DRAFT'), findsOneWidget);
    expect(find.text('SUBMITTED'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows the empty state when the page loads with zero counts', (tester) async {
    when(() => mockRepo.listStockCounts(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => []);

    await pumpApp(tester, const StockCountListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('No stock counts found'), findsOneWidget);
  });

  testWidgets('shows the interpolated error message when the repository throws', (tester) async {
    when(() => mockRepo.listStockCounts(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenThrow(Exception('connection refused'));

    await pumpApp(tester, const StockCountListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    // This screen's own _load() catch block interpolates the raw exception
    // directly (`'Could not load stock counts: $e'`) — no ErrorPresenter.
    expect(find.text('Could not load stock counts: Exception: connection refused'), findsOneWidget);
  });
}
