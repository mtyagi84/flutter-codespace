import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/features/inventory/data/models/stock_receipt_model.dart';
import 'package:sakal/features/inventory/domain/repositories/stock_receipt_repository.dart';
import 'package:sakal/features/inventory/presentation/providers/stock_receipt_providers.dart';
import 'package:sakal/features/inventory/presentation/screens/stock_receipt_list_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockStockReceiptRepository extends Mock implements StockReceiptRepository {}

void main() {
  late MockStockReceiptRepository mockRepo;

  setUp(() {
    mockRepo = MockStockReceiptRepository();
  });

  List<Override> overrides() => [
        stockReceiptRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  testWidgets('shows a loading indicator before the first page resolves', (tester) async {
    when(() => mockRepo.listReceipts(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) => Completer<List<StockReceiptHeader>>().future);

    await pumpApp(tester, const StockReceiptListScreen(), overrides: overrides(), session: testSession());
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders a card per receipt once the page loads', (tester) async {
    when(() => mockRepo.listReceipts(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => [
          StockReceiptHeader.fromJson(const {
            'receipt_no': 'SRC-001',
            'receipt_date': '2026-07-09',
            'from_location_id': 'loc-001',
            'from_location': {'location_name': 'Transit'},
            'to_location_id': 'loc-002',
            'to_location': {'location_name': 'Store C'},
            'source_transfer_no': 'TRF-001',
            'status': 'DRAFT',
          }),
          StockReceiptHeader.fromJson(const {
            'receipt_no': 'SRC-002',
            'receipt_date': '2026-07-10',
            'from_location_id': 'loc-003',
            'to_location_id': 'loc-004',
            'status': 'APPROVED',
          }),
        ]);

    await pumpApp(tester, const StockReceiptListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('SRC-001'), findsOneWidget);
    expect(find.text('SRC-002'), findsOneWidget);
    expect(find.text('Transit → Store C'), findsOneWidget);
    // Second receipt has empty from/to location names — rendered as em-dashes.
    expect(find.text('— → —'), findsOneWidget);
    // Date + source-transfer-no are combined into one line on the card.
    expect(find.text('09 Jul 2026 · TRF-001'), findsOneWidget);
    expect(find.text('10 Jul 2026 · —'), findsOneWidget);
    // This screen's own _statusBadge shows the raw status code.
    expect(find.text('DRAFT'), findsOneWidget);
    expect(find.text('APPROVED'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows the empty state when the page loads with zero receipts', (tester) async {
    when(() => mockRepo.listReceipts(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => []);

    await pumpApp(tester, const StockReceiptListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('No stock receipts found'), findsOneWidget);
  });

  testWidgets('shows the interpolated error message when the repository throws', (tester) async {
    when(() => mockRepo.listReceipts(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenThrow(Exception('connection refused'));

    await pumpApp(tester, const StockReceiptListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    // This screen's own _load() catch block interpolates the raw exception
    // directly (`'Could not load stock receipts: $e'`) — no ErrorPresenter.
    expect(find.text('Could not load stock receipts: Exception: connection refused'), findsOneWidget);
  });
}
