import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/features/inventory/data/models/stock_transfer_model.dart';
import 'package:sakal/features/inventory/domain/repositories/stock_transfer_repository.dart';
import 'package:sakal/features/inventory/presentation/providers/stock_transfer_providers.dart';
import 'package:sakal/features/inventory/presentation/screens/stock_transfer_list_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockStockTransferRepository extends Mock implements StockTransferRepository {}

void main() {
  late MockStockTransferRepository mockRepo;

  setUp(() {
    mockRepo = MockStockTransferRepository();
  });

  List<Override> overrides() => [
        stockTransferRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  testWidgets('shows a loading indicator before the first page resolves', (tester) async {
    when(() => mockRepo.listTransfers(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) => Completer<List<StockTransferHeader>>().future);

    await pumpApp(tester, const StockTransferListScreen(), overrides: overrides(), session: testSession());
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders a card per transfer once the page loads', (tester) async {
    when(() => mockRepo.listTransfers(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => [
          StockTransferHeader.fromJson(const {
            'transfer_no': 'TRF-001',
            'transfer_date': '2026-07-07',
            'from_location_id': 'loc-001',
            'from_location': {'location_name': 'Warehouse'},
            'to_location_id': 'loc-002',
            'to_location': {'location_name': 'Retail'},
            'against_request': false,
            'status': 'DRAFT',
          }),
          StockTransferHeader.fromJson(const {
            'transfer_no': 'TRF-002',
            'transfer_date': '2026-07-08',
            'from_location_id': 'loc-003',
            'to_location_id': 'loc-004',
            'against_request': false,
            'status': 'CLOSED',
          }),
        ]);

    await pumpApp(tester, const StockTransferListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('TRF-001'), findsOneWidget);
    expect(find.text('TRF-002'), findsOneWidget);
    expect(find.text('Warehouse → Retail'), findsOneWidget);
    // Second transfer has empty from/to location names — rendered as em-dashes.
    expect(find.text('— → —'), findsOneWidget);
    expect(find.text('07 Jul 2026'), findsOneWidget);
    expect(find.text('08 Jul 2026'), findsOneWidget);
    // This screen's own _statusBadge shows the raw status code, not a
    // human label (unlike Material Requisition/Stock Transfer Request).
    expect(find.text('DRAFT'), findsOneWidget);
    expect(find.text('CLOSED'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows the empty state when the page loads with zero transfers', (tester) async {
    when(() => mockRepo.listTransfers(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => []);

    await pumpApp(tester, const StockTransferListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('No stock transfers found'), findsOneWidget);
  });

  testWidgets('shows the interpolated error message when the repository throws', (tester) async {
    when(() => mockRepo.listTransfers(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenThrow(Exception('connection refused'));

    await pumpApp(tester, const StockTransferListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    // This screen's own _load() catch block interpolates the raw exception
    // directly (`'Could not load stock transfers: $e'`) — no ErrorPresenter.
    expect(find.text('Could not load stock transfers: Exception: connection refused'), findsOneWidget);
  });
}
