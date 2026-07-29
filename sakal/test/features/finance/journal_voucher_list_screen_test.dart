import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/features/finance/data/models/finance_voucher_model.dart';
import 'package:sakal/features/finance/domain/repositories/finance_voucher_repository.dart';
import 'package:sakal/features/finance/presentation/providers/finance_voucher_providers.dart';
import 'package:sakal/features/finance/presentation/screens/journal_voucher_list_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockFinanceVoucherRepository extends Mock implements FinanceVoucherRepository {}

void main() {
  late MockFinanceVoucherRepository mockRepo;

  setUp(() {
    mockRepo = MockFinanceVoucherRepository();
  });

  // SyncEngine(null) is a real instance, not a mock — with no Drift database
  // it degrades every read method to an empty/zero result (see the class's
  // own doc comment), which is exactly the "nothing pending" state these
  // tests want, with no need to mock it at all.
  final overrides = <Override>[
    financeVoucherRepositoryProvider.overrideWithValue(mockRepo),
    syncEngineProvider.overrideWithValue(SyncEngine(null)),
  ];

  testWidgets('shows a loading indicator before the first page resolves', (tester) async {
    // A fetchPage that never completes during this test — lets us inspect
    // the screen's state strictly before _load() finishes.
    when(() => mockRepo.listHeaders(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          locationId: any(named: 'locationId'),
          fromDate: any(named: 'fromDate'),
          toDate: any(named: 'toDate'),
          voucherTypeCode: any(named: 'voucherTypeCode'),
          isPosted: any(named: 'isPosted'),
          search: any(named: 'search'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) => Completer<List<FinanceVoucherHeader>>().future);

    await pumpApp(tester, const JournalVoucherListScreen(), overrides: overrides, session: testSession());
    await tester.pump(); // let initState's postFrameCallback fire and _load() start

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders a row per voucher once the page loads', (tester) async {
    when(() => mockRepo.listHeaders(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          locationId: any(named: 'locationId'),
          fromDate: any(named: 'fromDate'),
          toDate: any(named: 'toDate'),
          voucherTypeCode: any(named: 'voucherTypeCode'),
          isPosted: any(named: 'isPosted'),
          search: any(named: 'search'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => [
          FinanceVoucherHeader.fromJson(const {
            'trans_no': 'JV-001',
            'trans_date': '2026-07-01',
            'voucher_type_code': 'JV',
            'is_posted': true,
            'remarks': 'Month-end accrual',
          }),
          FinanceVoucherHeader.fromJson(const {
            'trans_no': 'JV-002',
            'trans_date': '2026-07-02',
            'voucher_type_code': 'JV',
            'is_posted': false,
            'remarks': '',
          }),
        ]);

    await pumpApp(tester, const JournalVoucherListScreen(), overrides: overrides, session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('JV-001'), findsOneWidget);
    expect(find.text('JV-002'), findsOneWidget);
    expect(find.text('Month-end accrual'), findsOneWidget);
    // The second voucher has an empty remarks string, which the row builder
    // renders as an em-dash placeholder rather than blank.
    expect(find.text('—'), findsOneWidget);
    expect(find.text('Posted'), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows the empty state when the page loads with zero vouchers', (tester) async {
    when(() => mockRepo.listHeaders(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          locationId: any(named: 'locationId'),
          fromDate: any(named: 'fromDate'),
          toDate: any(named: 'toDate'),
          voucherTypeCode: any(named: 'voucherTypeCode'),
          isPosted: any(named: 'isPosted'),
          search: any(named: 'search'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => []);

    await pumpApp(tester, const JournalVoucherListScreen(), overrides: overrides, session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('No journal vouchers found'), findsOneWidget);
  });

  testWidgets('shows a friendly error message (never the raw exception) when the repository throws', (tester) async {
    when(() => mockRepo.listHeaders(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          locationId: any(named: 'locationId'),
          fromDate: any(named: 'fromDate'),
          toDate: any(named: 'toDate'),
          voucherTypeCode: any(named: 'voucherTypeCode'),
          isPosted: any(named: 'isPosted'),
          search: any(named: 'search'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenThrow(Exception('connection refused'));

    await pumpApp(tester, const JournalVoucherListScreen(), overrides: overrides, session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('Unable to load journal vouchers. Please try again.'), findsOneWidget);
    expect(find.textContaining('connection refused'), findsNothing);
  });
}
