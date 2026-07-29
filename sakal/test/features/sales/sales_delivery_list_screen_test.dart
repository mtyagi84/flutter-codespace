import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/features/sales/data/models/sales_delivery_header.dart';
import 'package:sakal/features/sales/domain/repositories/sales_delivery_repository.dart';
import 'package:sakal/features/sales/presentation/providers/sales_delivery_providers.dart';
import 'package:sakal/features/sales/presentation/screens/sales_delivery_list_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockSalesDeliveryRepository extends Mock implements SalesDeliveryRepository {}

void main() {
  late MockSalesDeliveryRepository mockRepo;

  setUp(() {
    mockRepo = MockSalesDeliveryRepository();
  });

  List<Override> overrides() => [
        salesDeliveryRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  testWidgets('shows a loading indicator before the first page resolves', (tester) async {
    when(() => mockRepo.listDeliveries(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) => Completer<List<SalesDeliveryHeader>>().future);

    await pumpApp(tester, const SalesDeliveryListScreen(), overrides: overrides(), session: testSession());
    await tester.pump(); // let initState's postFrameCallback fire and _load() start

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders a card per delivery once the page loads', (tester) async {
    when(() => mockRepo.listDeliveries(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => [
          SalesDeliveryHeader.fromJson(const {
            'delivery_no': 'SD-001',
            'delivery_date': '2026-07-11',
            'invoice_no': 'INV-200',
            'customer': {'account_code': 'CUST02', 'account_name': 'Beta Corp'},
            'location': {'location_name': 'Main Warehouse'},
            'status': 'DRAFT',
          }),
          SalesDeliveryHeader.fromJson(const {
            'delivery_no': 'SD-002',
            'delivery_date': '2026-07-12',
            'invoice_no': 'INV-201',
            'customer': {'account_code': 'CUST03', 'account_name': 'Gamma Ltd'},
            'status': 'APPROVED',
          }),
        ]);

    await pumpApp(tester, const SalesDeliveryListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('SD-001'), findsOneWidget);
    expect(find.text('SD-002'), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);
    expect(find.text('Approved'), findsOneWidget);
    expect(find.text('[CUST02] Beta Corp'), findsOneWidget);
    expect(find.text('[CUST03] Gamma Ltd'), findsOneWidget);
    expect(find.text('Main Warehouse'), findsOneWidget);
    // SD-002 has no location embed at all.
    expect(find.text('—'), findsOneWidget);
    expect(find.text('Against INV-200 · 11 Jul 2026'), findsOneWidget);
    expect(find.text('Against INV-201 · 12 Jul 2026'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows the empty state when the page loads with zero deliveries', (tester) async {
    when(() => mockRepo.listDeliveries(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => []);

    await pumpApp(tester, const SalesDeliveryListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('No sales deliveries found'), findsOneWidget);
  });

  // This screen builds '_error' inline ('Could not load sales deliveries:
  // $e') rather than through ErrorPresenter.format — the raw exception text
  // is genuinely what renders here.
  testWidgets('shows the load-error text when the repository throws', (tester) async {
    when(() => mockRepo.listDeliveries(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenThrow(Exception('connection refused'));

    await pumpApp(tester, const SalesDeliveryListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('Could not load sales deliveries: Exception: connection refused'), findsOneWidget);
  });
}
