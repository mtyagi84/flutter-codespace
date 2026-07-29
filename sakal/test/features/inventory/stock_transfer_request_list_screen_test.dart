import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/features/inventory/data/models/stock_transfer_request_model.dart';
import 'package:sakal/features/inventory/domain/repositories/stock_transfer_request_repository.dart';
import 'package:sakal/features/inventory/presentation/providers/stock_transfer_request_providers.dart';
import 'package:sakal/features/inventory/presentation/screens/stock_transfer_request_list_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockStockTransferRequestRepository extends Mock implements StockTransferRequestRepository {}

void main() {
  late MockStockTransferRequestRepository mockRepo;

  setUp(() {
    mockRepo = MockStockTransferRequestRepository();
  });

  List<Override> overrides() => [
        stockTransferRequestRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  testWidgets('shows a loading indicator before the first page resolves', (tester) async {
    when(() => mockRepo.listRequests(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) => Completer<List<StockTransferRequestHeader>>().future);

    await pumpApp(tester, const StockTransferRequestListScreen(), overrides: overrides(), session: testSession());
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders a card per request once the page loads', (tester) async {
    when(() => mockRepo.listRequests(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => [
          StockTransferRequestHeader.fromJson(const {
            'request_no': 'STR-001',
            'request_date': '2026-07-05',
            'from_location_id': 'loc-001',
            'from_location': {'location_name': 'Store A'},
            'to_location_id': 'loc-002',
            'to_location': {'location_name': 'Store B'},
            'status': 'DRAFT',
          }),
          StockTransferRequestHeader.fromJson(const {
            'request_no': 'STR-002',
            'request_date': '2026-07-06',
            'from_location_id': 'loc-003',
            'to_location_id': 'loc-004',
            'status': 'PARTIALLY_TRANSFERRED',
          }),
        ]);

    await pumpApp(tester, const StockTransferRequestListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('STR-001'), findsOneWidget);
    expect(find.text('STR-002'), findsOneWidget);
    expect(find.text('Store A → Store B'), findsOneWidget);
    // Second request has empty from/to location names — rendered as em-dashes.
    expect(find.text('— → —'), findsOneWidget);
    expect(find.text('05 Jul 2026'), findsOneWidget);
    expect(find.text('06 Jul 2026'), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);
    expect(find.text('Partially Transferred'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows the empty state when the page loads with zero requests', (tester) async {
    when(() => mockRepo.listRequests(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => []);

    await pumpApp(tester, const StockTransferRequestListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('No stock transfer requests found'), findsOneWidget);
  });

  testWidgets('shows the interpolated error message when the repository throws', (tester) async {
    when(() => mockRepo.listRequests(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenThrow(Exception('connection refused'));

    await pumpApp(tester, const StockTransferRequestListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    // This screen's own _load() catch block interpolates the raw exception
    // directly (`'Could not load stock transfer requests: $e'`) — no
    // ErrorPresenter.
    expect(find.text('Could not load stock transfer requests: Exception: connection refused'), findsOneWidget);
  });
}
