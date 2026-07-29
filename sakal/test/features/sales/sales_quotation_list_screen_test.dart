import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/features/sales/data/models/sales_quotation_header.dart';
import 'package:sakal/features/sales/domain/repositories/sales_quotation_repository.dart';
import 'package:sakal/features/sales/presentation/providers/sales_quotation_providers.dart';
import 'package:sakal/features/sales/presentation/screens/sales_quotation_list_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockSalesQuotationRepository extends Mock implements SalesQuotationRepository {}

void main() {
  late MockSalesQuotationRepository mockRepo;

  setUp(() {
    mockRepo = MockSalesQuotationRepository();
  });

  // Built fresh inside each test (never at the top of main()) — mockRepo is
  // a `late` variable only assigned once setUp() runs before each test; see
  // the finance pilot (journal_voucher_list_screen_test.dart) for the
  // LateError this avoids.
  List<Override> overrides() => [
        salesQuotationRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  testWidgets('shows a loading indicator before the first page resolves', (tester) async {
    when(() => mockRepo.listQuotations(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) => Completer<List<SalesQuotationHeader>>().future);

    await pumpApp(tester, const SalesQuotationListScreen(), overrides: overrides(), session: testSession());
    await tester.pump(); // let initState's postFrameCallback fire and _load() start

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders a card per quotation once the page loads', (tester) async {
    when(() => mockRepo.listQuotations(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => [
          SalesQuotationHeader.fromJson(const {
            'quotation_no': 'SQ-001',
            'quotation_date': '2026-07-01',
            // Deliberately far in the future — _isExpired() compares this
            // against DateTime.now(), and a near-future date here would
            // eventually flip this fixture's status badge from "Sent" to
            // "Expired" as real time passes, breaking the test later.
            'valid_until_date': '2099-01-01',
            'customer_type': 'CUSTOMER',
            'party_name': 'Acme Traders',
            'status': 'SENT',
            'grand_total': 1000.0,
            'currency': {'currency_id': 'USD'},
          }),
          SalesQuotationHeader.fromJson(const {
            'quotation_no': 'SQ-002',
            'quotation_date': '2026-07-02',
            'valid_until_date': '2099-01-02',
            'customer_type': 'PROSPECT',
            'party_name': 'New Prospect Co',
            'status': 'DRAFT',
            'grand_total': 250.0,
            'currency': {'currency_id': 'USD'},
          }),
        ]);

    await pumpApp(tester, const SalesQuotationListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('SQ-001'), findsOneWidget);
    expect(find.text('SQ-002'), findsOneWidget);
    expect(find.text('Acme Traders'), findsOneWidget);
    expect(find.text('New Prospect Co'), findsOneWidget);
    // Only SQ-002 is a prospect — the "Prospect" tag should appear exactly once.
    expect(find.text('Prospect'), findsOneWidget);
    expect(find.text('Sent'), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);
    expect(find.text('USD 1,000.00'), findsOneWidget);
    expect(find.text('USD 250.00'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows the empty state when the page loads with zero quotations', (tester) async {
    when(() => mockRepo.listQuotations(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => []);

    await pumpApp(tester, const SalesQuotationListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('No quotations found'), findsOneWidget);
  });

  // This screen builds its own '_error' string inline ('Could not load
  // quotations: $e') rather than going through ErrorPresenter.format — so
  // unlike the Finance pilot's assertion, the raw exception text IS what a
  // user would see here. This test documents the screen's actual current
  // behavior, not the app-wide "never leak a raw exception" convention.
  testWidgets('shows the load-error text when the repository throws', (tester) async {
    when(() => mockRepo.listQuotations(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenThrow(Exception('connection refused'));

    await pumpApp(tester, const SalesQuotationListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('Could not load quotations: Exception: connection refused'), findsOneWidget);
  });
}
