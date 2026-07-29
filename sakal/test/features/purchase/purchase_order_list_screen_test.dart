import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/features/purchase/data/models/purchase_order_model.dart';
import 'package:sakal/features/purchase/domain/repositories/purchase_order_repository.dart';
import 'package:sakal/features/purchase/presentation/providers/purchase_order_providers.dart';
import 'package:sakal/features/purchase/presentation/screens/purchase_order_list_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockPurchaseOrderRepository extends Mock implements PurchaseOrderRepository {}

void main() {
  late MockPurchaseOrderRepository mockRepo;

  setUp(() {
    mockRepo = MockPurchaseOrderRepository();
  });

  // Built fresh inside each test — see journal_voucher_list_screen_test.dart's
  // comment: mockRepo is only assigned once setUp() runs before each test, so
  // building this list at the top of main() throws LateError.
  List<Override> overrides() => [
        purchaseOrderRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  testWidgets('shows a loading indicator before the first page resolves', (tester) async {
    when(() => mockRepo.listOrders(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) => Completer<List<PurchaseOrderModel>>().future);

    await pumpApp(tester, const PurchaseOrderListScreen(), overrides: overrides(), session: testSession());
    await tester.pump(); // let initState's postFrameCallback fire and _load() start

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders a row per order once the page loads', (tester) async {
    when(() => mockRepo.listOrders(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => [
          PurchaseOrderModel.fromJson(const {
            'id': 'po-1',
            'client_id': 'client-001',
            'company_id': 'company-001',
            'location_id': 'loc-001',
            'order_no': 'PO-001',
            'order_date': '2026-07-01',
            'po_type': 'IMPORT',
            'supplier_id': 'sup-001',
            'supplier': {'account_code': 'SUP01', 'account_name': 'Global Supplies'},
            'po_currency_id': 'cur-usd',
            'currency': {'currency_id': 'USD'},
            'grand_total': 2500.75,
            'status': 'APPROVED',
          }),
          PurchaseOrderModel.fromJson(const {
            'id': 'po-2',
            'client_id': 'client-001',
            'company_id': 'company-001',
            'location_id': 'loc-001',
            'order_no': 'PO-002',
            'order_date': '2026-07-02',
            'po_type': 'LOCAL',
            'supplier_id': 'sup-002',
            'po_currency_id': 'cur-local',
            'grand_total': 0,
            'status': 'DRAFT',
          }),
        ]);

    await pumpApp(tester, const PurchaseOrderListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('PO-001'), findsOneWidget);
    expect(find.text('PO-002'), findsOneWidget);
    expect(find.text('Import'), findsOneWidget);
    expect(find.text('Local'), findsOneWidget);
    expect(find.text('[SUP01] Global Supplies'), findsOneWidget);
    // PO-002 has no supplier embed at all — falls back to an em-dash.
    expect(find.text('—'), findsOneWidget);
    expect(find.text('USD 2500.75'), findsOneWidget);
    // PO-002 has no currency embed, so the code is an empty string —
    // '${null ?? ''} ${0.00...}' leaves a leading space before the amount.
    expect(find.text(' 0.00'), findsOneWidget);
    expect(find.text('Approved'), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows the empty state when the page loads with zero orders', (tester) async {
    when(() => mockRepo.listOrders(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => []);

    await pumpApp(tester, const PurchaseOrderListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('No purchase orders found'), findsOneWidget);
  });

  testWidgets('shows an error message when the repository throws', (tester) async {
    when(() => mockRepo.listOrders(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenThrow(Exception('connection refused'));

    await pumpApp(tester, const PurchaseOrderListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    // This screen predates the ErrorPresenter rollout and still interpolates
    // the raw exception directly (`'Could not load purchase orders: $e'`) —
    // this test asserts the CURRENT behavior, not the ideal one.
    expect(find.text('Could not load purchase orders: Exception: connection refused'), findsOneWidget);
  });
}
