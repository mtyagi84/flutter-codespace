import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/features/purchase/data/models/purchase_invoice_model.dart';
import 'package:sakal/features/purchase/domain/repositories/purchase_invoice_repository.dart';
import 'package:sakal/features/purchase/presentation/providers/purchase_invoice_providers.dart';
import 'package:sakal/features/purchase/presentation/screens/purchase_invoice_list_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockPurchaseInvoiceRepository extends Mock implements PurchaseInvoiceRepository {}

void main() {
  late MockPurchaseInvoiceRepository mockRepo;

  setUp(() {
    mockRepo = MockPurchaseInvoiceRepository();
  });

  // Built fresh inside each test — see journal_voucher_list_screen_test.dart's
  // comment: mockRepo is only assigned once setUp() runs before each test, so
  // building this list at the top of main() throws LateError.
  //
  // Unlike the other 3 Purchase list screens, this one has no
  // syncEngineProvider/pendingDocumentIds usage at all (no offline
  // pending-sync badge on this screen) — a single await, no Future.wait.
  List<Override> overrides() => [
        purchaseInvoiceRepositoryProvider.overrideWithValue(mockRepo),
      ];

  testWidgets('shows a loading indicator before the first page resolves', (tester) async {
    when(() => mockRepo.listPurchaseInvoices(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) => Completer<List<PurchaseInvoiceModel>>().future);

    await pumpApp(tester, const PurchaseInvoiceListScreen(), overrides: overrides(), session: testSession());
    await tester.pump(); // let initState's postFrameCallback fire and _load() start

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders a row per bill once the page loads', (tester) async {
    when(() => mockRepo.listPurchaseInvoices(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => [
          PurchaseInvoiceModel.fromJson(const {
            'id': 'pinv-1',
            'client_id': 'client-001',
            'company_id': 'company-001',
            'location_id': 'loc-001',
            'invoice_no': 'PINV-001',
            'invoice_date': '2026-07-01',
            'supplier_id': 'sup-001',
            'supplier': {'account_code': 'SUP01', 'account_name': 'ABC Traders'},
            'supplier_invoice_no': 'SINV-500',
            'supplier_invoice_date': '2026-06-30',
            'currency': {'currency_id': 'USD'},
            'invoice_total': 3200.0,
            'status': 'APPROVED',
          }),
          PurchaseInvoiceModel.fromJson(const {
            'id': 'pinv-2',
            'client_id': 'client-001',
            'company_id': 'company-001',
            'location_id': 'loc-001',
            'invoice_no': 'PINV-002',
            'invoice_date': '2026-07-02',
            'supplier_id': 'sup-002',
            'supplier_invoice_no': 'SINV-501',
            'supplier_invoice_date': '2026-07-01',
            'invoice_total': 0,
            'status': 'DRAFT',
          }),
        ]);

    await pumpApp(tester, const PurchaseInvoiceListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('PINV-001'), findsOneWidget);
    expect(find.text('PINV-002'), findsOneWidget);
    expect(find.text('Supplier Inv. SINV-500 · 01 Jul 2026'), findsOneWidget);
    expect(find.text('Supplier Inv. SINV-501 · 02 Jul 2026'), findsOneWidget);
    expect(find.text('[SUP01] ABC Traders'), findsOneWidget);
    // Bill 2 has no supplier embed at all — falls back to an em-dash.
    expect(find.text('—'), findsOneWidget);
    expect(find.text('USD 3200.00'), findsOneWidget);
    // Bill 2 has no currency embed, so the code is an empty string —
    // '${null ?? ''} ${0.00...}' leaves a leading space before the amount.
    expect(find.text(' 0.00'), findsOneWidget);
    expect(find.text('Approved'), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows the empty state when the page loads with zero bills', (tester) async {
    when(() => mockRepo.listPurchaseInvoices(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => []);

    await pumpApp(tester, const PurchaseInvoiceListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('No purchase bills found'), findsOneWidget);
  });

  testWidgets('shows an error message when the repository throws', (tester) async {
    when(() => mockRepo.listPurchaseInvoices(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenThrow(Exception('connection refused'));

    await pumpApp(tester, const PurchaseInvoiceListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    // This screen predates the ErrorPresenter rollout and still interpolates
    // the raw exception directly (`'Could not load purchase bills: $e'`) —
    // this test asserts the CURRENT behavior, not the ideal one.
    expect(find.text('Could not load purchase bills: Exception: connection refused'), findsOneWidget);
  });
}
