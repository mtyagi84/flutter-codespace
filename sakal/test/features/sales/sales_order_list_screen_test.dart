import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/features/sales/data/models/sales_order_header.dart';
import 'package:sakal/features/sales/domain/repositories/sales_order_repository.dart';
import 'package:sakal/features/sales/presentation/providers/sales_order_providers.dart';
import 'package:sakal/features/sales/presentation/screens/sales_order_list_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockSalesOrderRepository extends Mock implements SalesOrderRepository {}

void main() {
  late MockSalesOrderRepository mockRepo;

  setUp(() {
    mockRepo = MockSalesOrderRepository();
  });

  List<Override> overrides() => [
        salesOrderRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  testWidgets('shows a loading indicator before the first page resolves', (tester) async {
    when(() => mockRepo.listOrders(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          orderMode: any(named: 'orderMode'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) => Completer<List<SalesOrderHeader>>().future);

    await pumpApp(tester, const SalesOrderListScreen(), overrides: overrides(), session: testSession());
    await tester.pump(); // let initState's postFrameCallback fire and _load() start

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders a card per order once the page loads', (tester) async {
    when(() => mockRepo.listOrders(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          orderMode: any(named: 'orderMode'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => [
          SalesOrderHeader.fromJson(const {
            'order_no': 'SO-001',
            'order_date': '2026-07-01',
            'order_mode': 'DIRECT',
            'customer': {'account_name': 'Acme Traders'},
            'customer_po_ref': 'PO-77',
            'status': 'DRAFT',
            'grand_total': 500.0,
            'currency': {'currency_id': 'USD'},
          }),
          SalesOrderHeader.fromJson(const {
            'order_no': 'SO-002',
            'order_date': '2026-07-02',
            'order_mode': 'AGAINST_QUOTATION',
            'source_quotation_no': 'SQ-002',
            'customer': {'account_name': 'Beta Corp'},
            'customer_po_ref': '',
            'status': 'APPROVED',
            'grand_total': 2000.0,
            'currency': {'currency_id': 'USD'},
          }),
        ]);

    await pumpApp(tester, const SalesOrderListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('SO-001'), findsOneWidget);
    expect(find.text('SO-002'), findsOneWidget);
    expect(find.text('Acme Traders'), findsOneWidget);
    expect(find.text('Beta Corp'), findsOneWidget);
    expect(find.text('Direct'), findsOneWidget);
    expect(find.text('Against SQ'), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);
    expect(find.text('Approved'), findsOneWidget);
    expect(find.text('From SQ-002'), findsOneWidget);
    expect(find.text('USD 500.00'), findsOneWidget);
    expect(find.text('USD 2,000.00'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows the empty state when the page loads with zero orders', (tester) async {
    when(() => mockRepo.listOrders(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          orderMode: any(named: 'orderMode'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => []);

    await pumpApp(tester, const SalesOrderListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('No sales orders found'), findsOneWidget);
  });

  // Like the Quotation screen, this screen builds '_error' inline
  // ('Could not load orders: $e') rather than through ErrorPresenter.format
  // — the raw exception text is genuinely what renders here.
  testWidgets('shows the load-error text when the repository throws', (tester) async {
    when(() => mockRepo.listOrders(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          orderMode: any(named: 'orderMode'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenThrow(Exception('connection refused'));

    await pumpApp(tester, const SalesOrderListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('Could not load orders: Exception: connection refused'), findsOneWidget);
  });
}
