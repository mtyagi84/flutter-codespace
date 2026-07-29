import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/features/sales/data/models/sales_return_header.dart';
import 'package:sakal/features/sales/domain/repositories/sales_return_repository.dart';
import 'package:sakal/features/sales/presentation/providers/sales_return_providers.dart';
import 'package:sakal/features/sales/presentation/screens/sales_return_list_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockSalesReturnRepository extends Mock implements SalesReturnRepository {}

void main() {
  late MockSalesReturnRepository mockRepo;

  setUp(() {
    mockRepo = MockSalesReturnRepository();
  });

  List<Override> overrides() => [
        salesReturnRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  testWidgets('shows a loading indicator before the first page resolves', (tester) async {
    when(() => mockRepo.listReturns(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) => Completer<List<SalesReturnHeader>>().future);

    await pumpApp(tester, const SalesReturnListScreen(), overrides: overrides(), session: testSession());
    await tester.pump(); // let initState's postFrameCallback fire and _load() start

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders a card per return once the page loads', (tester) async {
    when(() => mockRepo.listReturns(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => [
          SalesReturnHeader.fromJson(const {
            'return_no': 'SR-001',
            'return_date': '2026-07-10',
            'invoice_no': 'INV-100',
            'customer': {'account_code': 'CUST01', 'account_name': 'Acme Traders'},
            'return_total': 150.5,
            'status': 'DRAFT',
          }),
          SalesReturnHeader.fromJson(const {
            'return_no': 'SR-002',
            'return_total': 0,
            'status': 'APPROVED',
          }),
        ]);

    await pumpApp(tester, const SalesReturnListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('SR-001'), findsOneWidget);
    expect(find.text('SR-002'), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);
    expect(find.text('Approved'), findsOneWidget);
    expect(find.text('[CUST01] Acme Traders'), findsOneWidget);
    expect(find.text('150.50'), findsOneWidget);
    expect(find.text('0.00'), findsOneWidget);
    expect(find.text('Against INV-100 · 10 Jul 2026'), findsOneWidget);
    // SR-002 has no invoice_no/return_date/customer at all.
    expect(find.text('Against — · —'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows the empty state when the page loads with zero returns', (tester) async {
    when(() => mockRepo.listReturns(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => []);

    await pumpApp(tester, const SalesReturnListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('No sales returns found'), findsOneWidget);
  });

  // This screen builds '_error' inline ('Could not load sales returns: $e')
  // rather than through ErrorPresenter.format — the raw exception text is
  // genuinely what renders here.
  testWidgets('shows the load-error text when the repository throws', (tester) async {
    when(() => mockRepo.listReturns(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenThrow(Exception('connection refused'));

    await pumpApp(tester, const SalesReturnListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('Could not load sales returns: Exception: connection refused'), findsOneWidget);
  });
}
