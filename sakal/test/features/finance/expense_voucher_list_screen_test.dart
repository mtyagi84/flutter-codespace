import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/features/finance/data/models/expense_voucher_model.dart';
import 'package:sakal/features/finance/domain/repositories/expense_voucher_repository.dart';
import 'package:sakal/features/finance/presentation/providers/expense_voucher_providers.dart';
import 'package:sakal/features/finance/presentation/screens/expense_voucher_list_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockExpenseVoucherRepository extends Mock implements ExpenseVoucherRepository {}

void main() {
  late MockExpenseVoucherRepository mockRepo;

  setUp(() {
    mockRepo = MockExpenseVoucherRepository();
  });

  // Built fresh inside each test — see journal_voucher_list_screen_test.dart's
  // comment: mockRepo is only assigned once setUp() runs before each test, so
  // building this list at the top of main() throws LateError.
  //
  // This screen uses PagedListController (not the older Future.wait shape) —
  // its own fetchPage calls listVouchers(clientId, companyId, status, search,
  // limit, offset), a different repository/method from the other two Finance
  // list screens in this batch.
  List<Override> overrides() => [
        expenseVoucherRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  testWidgets('shows a loading indicator before the first page resolves', (tester) async {
    when(() => mockRepo.listVouchers(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          status: any(named: 'status'),
          search: any(named: 'search'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) => Completer<List<ExpenseVoucherHeader>>().future);

    await pumpApp(tester, const ExpenseVoucherListScreen(), overrides: overrides(), session: testSession());
    await tester.pump(); // let initState's postFrameCallback fire and _load() start

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders a row per voucher once the page loads', (tester) async {
    when(() => mockRepo.listVouchers(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          status: any(named: 'status'),
          search: any(named: 'search'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => [
          ExpenseVoucherHeader.fromJson(const {
            'trans_no': 'EXV-001',
            'trans_date': '2026-07-01',
            'supplier_id': 'sup-001',
            'supplier': {'account_code': 'SUP01', 'account_name': 'Electric Co'},
            'bill_no': 'BILL-100',
            'bill_date': '2026-06-28',
            'status': 'APPROVED',
            'remarks': '',
          }),
          ExpenseVoucherHeader.fromJson(const {
            'trans_no': 'EXV-002',
            'trans_date': '2026-07-02',
            'supplier_id': '',
            'bill_no': '',
            'bill_date': '',
            'status': 'DRAFT',
            'remarks': '',
          }),
        ]);

    await pumpApp(tester, const ExpenseVoucherListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('EXV-001'), findsOneWidget);
    expect(find.text('EXV-002'), findsOneWidget);
    expect(find.text('[SUP01] Electric Co'), findsOneWidget);
    // Voucher 2 has no supplier at all — the row/card builder falls back to
    // an em-dash placeholder for the supplier name.
    expect(find.text('—'), findsOneWidget);
    expect(find.text('01 Jul 2026 · Bill BILL-100'), findsOneWidget);
    expect(find.text('02 Jul 2026 · Bill —'), findsOneWidget);
    expect(find.text('Posted'), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows the empty state when the page loads with zero vouchers', (tester) async {
    when(() => mockRepo.listVouchers(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          status: any(named: 'status'),
          search: any(named: 'search'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => []);

    await pumpApp(tester, const ExpenseVoucherListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('No expense vouchers found'), findsOneWidget);
  });

  testWidgets('shows a friendly error message (never the raw exception) when the repository throws', (tester) async {
    when(() => mockRepo.listVouchers(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          status: any(named: 'status'),
          search: any(named: 'search'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenThrow(Exception('connection refused'));

    await pumpApp(tester, const ExpenseVoucherListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('Unable to load expense vouchers. Please try again.'), findsOneWidget);
    expect(find.textContaining('connection refused'), findsNothing);
  });
}
