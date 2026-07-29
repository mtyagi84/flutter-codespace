import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/features/inventory/data/models/opening_stock_model.dart';
import 'package:sakal/features/inventory/domain/repositories/opening_stock_repository.dart';
import 'package:sakal/features/inventory/presentation/providers/opening_stock_providers.dart';
import 'package:sakal/features/inventory/presentation/screens/opening_stock_list_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockOpeningStockRepository extends Mock implements OpeningStockRepository {}

void main() {
  late MockOpeningStockRepository mockRepo;

  setUp(() {
    mockRepo = MockOpeningStockRepository();
  });

  List<Override> overrides() => [
        openingStockRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  testWidgets('shows a loading indicator before the first page resolves', (tester) async {
    when(() => mockRepo.listOpeningStocks(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) => Completer<List<OpeningStockHeader>>().future);

    await pumpApp(tester, const OpeningStockListScreen(), overrides: overrides(), session: testSession());
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders a card per entry once the page loads', (tester) async {
    when(() => mockRepo.listOpeningStocks(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => [
          OpeningStockHeader.fromJson(const {
            'opening_no': 'OPST-001',
            'opening_date': '2026-07-13',
            'location_id': 'loc-001',
            'location': {'location_name': 'Main Store'},
            'status': 'DRAFT',
          }),
          OpeningStockHeader.fromJson(const {
            'opening_no': 'OPST-002',
            'opening_date': '2026-07-14',
            'location_id': 'loc-002',
            'status': 'APPROVED',
          }),
        ]);

    await pumpApp(tester, const OpeningStockListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('OPST-001'), findsOneWidget);
    expect(find.text('OPST-002'), findsOneWidget);
    expect(find.text('13 Jul 2026'), findsOneWidget);
    expect(find.text('14 Jul 2026'), findsOneWidget);
    expect(find.text('Main Store'), findsOneWidget);
    // Second entry has an empty locationName — rendered as an em-dash.
    expect(find.text('—'), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);
    expect(find.text('Approved'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows the empty state when the page loads with zero entries', (tester) async {
    when(() => mockRepo.listOpeningStocks(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => []);

    await pumpApp(tester, const OpeningStockListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('No opening stock entries found'), findsOneWidget);
  });

  testWidgets('shows the interpolated error message when the repository throws', (tester) async {
    when(() => mockRepo.listOpeningStocks(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenThrow(Exception('connection refused'));

    await pumpApp(tester, const OpeningStockListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    // This screen's own _load() catch block interpolates the raw exception
    // directly (`'Could not load opening stock entries: $e'`) — no
    // ErrorPresenter.
    expect(find.text('Could not load opening stock entries: Exception: connection refused'), findsOneWidget);
  });
}
