import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/features/sales/data/models/cash_receipt_header.dart';
import 'package:sakal/features/sales/domain/repositories/cash_receipt_repository.dart';
import 'package:sakal/features/sales/presentation/providers/cash_receipt_providers.dart';
import 'package:sakal/features/sales/presentation/screens/cash_receipt_list_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockCashReceiptRepository extends Mock implements CashReceiptRepository {}

void main() {
  late MockCashReceiptRepository mockRepo;

  setUp(() {
    mockRepo = MockCashReceiptRepository();
  });

  List<Override> overrides() => [
        cashReceiptRepositoryProvider.overrideWithValue(mockRepo),
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
        )).thenAnswer((_) => Completer<List<CashReceiptHeader>>().future);

    await pumpApp(tester, const CashReceiptListScreen(), overrides: overrides(), session: testSession());
    await tester.pump(); // let initState's postFrameCallback fire and _load() start

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
          CashReceiptHeader.fromJson(const {
            'receipt_no': 'CR-001',
            'receipt_date': '2026-07-15',
            'customer': {'account_code': 'CUST04', 'account_name': 'Delta LLC'},
            'location': {'location_name': 'Shop A'},
            'local_amount': 750.0,
            'base_amount': 0,
            'status': 'DRAFT',
          }),
          CashReceiptHeader.fromJson(const {
            'receipt_no': 'CR-002',
            'receipt_date': '2026-07-16',
            'location': {'location_name': 'Shop B'},
            'local_amount': 0,
            'base_amount': 500.0,
            'status': 'APPROVED',
          }),
        ]);

    await pumpApp(tester, const CashReceiptListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('CR-001'), findsOneWidget);
    expect(find.text('CR-002'), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);
    expect(find.text('Approved'), findsOneWidget);
    expect(find.text('[CUST04] Delta LLC'), findsOneWidget);
    // CR-002 has no customer embed at all.
    expect(find.text('—'), findsOneWidget);
    expect(find.text('Shop A'), findsOneWidget);
    expect(find.text('Shop B'), findsOneWidget);
    // CR-001: only local_amount > 0. CR-002: only base_amount > 0 (labeled "(base)").
    expect(find.text('750.00'), findsOneWidget);
    expect(find.text('500.00 (base)'), findsOneWidget);
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

    await pumpApp(tester, const CashReceiptListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('No cash receipts found'), findsOneWidget);
  });

  testWidgets('shows a friendly error message (never the raw exception) when the repository throws', (tester) async {
    when(() => mockRepo.listReceipts(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenThrow(Exception('connection refused'));

    await pumpApp(tester, const CashReceiptListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('Unable to load cash receipts. Please try again.'), findsOneWidget);
    expect(find.textContaining('connection refused'), findsNothing);
  });
}
