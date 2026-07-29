import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/features/sales/data/models/sales_invoice_header.dart';
import 'package:sakal/features/sales/domain/repositories/sales_invoice_repository.dart';
import 'package:sakal/features/sales/presentation/providers/sales_invoice_providers.dart';
import 'package:sakal/features/sales/presentation/screens/sales_invoice_list_screen.dart';

import '../../test_helpers/pump_app.dart';

// Only the LIST screen is covered here. sales_invoice_entry_screen.dart is
// explicitly out of scope for this pass — batch/serial/FEFO/charges make it
// far too complex to fixture safely without much deeper study.
class MockSalesInvoiceRepository extends Mock implements SalesInvoiceRepository {}

void main() {
  late MockSalesInvoiceRepository mockRepo;

  setUp(() {
    mockRepo = MockSalesInvoiceRepository();
  });

  // NOTE: `_load()` also fires an `unawaited(_loadDeliveryStatuses(...))`
  // call that reads `salesDeliveryRepositoryProvider` — but only when at
  // least one loaded row has `stockDispatchMode == 'DEFERRED'`. Every
  // fixture row below omits `stock_dispatch_mode`, which defaults to
  // 'IMMEDIATE' (see SalesInvoiceHeader.fromJson), so that lookup never
  // fires and `salesDeliveryRepositoryProvider` deliberately does NOT need
  // to be overridden/stubbed for these tests.
  List<Override> overrides() => [
        salesInvoiceRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  testWidgets('shows a loading indicator before the first page resolves', (tester) async {
    when(() => mockRepo.listInvoices(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          saleType: any(named: 'saleType'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) => Completer<List<SalesInvoiceHeader>>().future);

    await pumpApp(tester, const SalesInvoiceListScreen(), overrides: overrides(), session: testSession());
    await tester.pump(); // let initState's postFrameCallback fire and _load() start

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders a card per invoice once the page loads', (tester) async {
    when(() => mockRepo.listInvoices(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          saleType: any(named: 'saleType'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => [
          SalesInvoiceHeader.fromJson(const {
            'invoice_no': 'SI-001',
            'invoice_date': '2026-07-01',
            'sale_type': 'CASH',
            'customer': {'account_name': 'Cash Customer'},
            'party_name': '',
            'status': 'DRAFT',
            'grand_total': 100.0,
            'currency': {'currency_id': 'USD'},
          }),
          SalesInvoiceHeader.fromJson(const {
            'invoice_no': 'SI-002',
            'invoice_date': '2026-07-02',
            'sale_type': 'CREDIT',
            'party_name': 'Walk-in Ltd',
            'status': 'APPROVED',
            'grand_total': 5000.0,
            'currency': {'currency_id': 'USD'},
          }),
        ]);

    await pumpApp(tester, const SalesInvoiceListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('SI-001'), findsOneWidget);
    expect(find.text('SI-002'), findsOneWidget);
    expect(find.text('Cash Customer'), findsOneWidget);
    expect(find.text('Walk-in Ltd'), findsOneWidget);
    expect(find.text('Cash'), findsOneWidget);
    expect(find.text('Credit'), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);
    expect(find.text('Approved'), findsOneWidget);
    expect(find.text('USD 100.00'), findsOneWidget);
    expect(find.text('USD 5,000.00'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows the empty state when the page loads with zero invoices', (tester) async {
    when(() => mockRepo.listInvoices(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          saleType: any(named: 'saleType'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => []);

    await pumpApp(tester, const SalesInvoiceListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('No invoices found'), findsOneWidget);
  });

  // This screen builds '_error' inline ('Could not load invoices: $e')
  // rather than through ErrorPresenter.format — the raw exception text is
  // genuinely what renders here.
  testWidgets('shows the load-error text when the repository throws', (tester) async {
    when(() => mockRepo.listInvoices(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          saleType: any(named: 'saleType'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenThrow(Exception('connection refused'));

    await pumpApp(tester, const SalesInvoiceListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('Could not load invoices: Exception: connection refused'), findsOneWidget);
  });
}
