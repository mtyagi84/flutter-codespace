import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/features/purchase/data/models/grn_model.dart';
import 'package:sakal/features/purchase/domain/repositories/grn_repository.dart';
import 'package:sakal/features/purchase/presentation/providers/grn_providers.dart';
import 'package:sakal/features/purchase/presentation/screens/grn_list_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockGrnRepository extends Mock implements GrnRepository {}

void main() {
  late MockGrnRepository mockRepo;

  setUp(() {
    mockRepo = MockGrnRepository();
  });

  // Built fresh inside each test — see journal_voucher_list_screen_test.dart's
  // comment: mockRepo is only assigned once setUp() runs before each test, so
  // building this list at the top of main() throws LateError.
  List<Override> overrides() => [
        grnRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  testWidgets('shows a loading indicator before the first page resolves', (tester) async {
    when(() => mockRepo.listGrns(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) => Completer<List<GrnModel>>().future);

    await pumpApp(tester, const GrnListScreen(), overrides: overrides(), session: testSession());
    await tester.pump(); // let initState's postFrameCallback fire and _load() start

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders a row per GRN once the page loads', (tester) async {
    when(() => mockRepo.listGrns(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => [
          GrnModel.fromJson(const {
            'id': 'grn-1',
            'client_id': 'client-001',
            'company_id': 'company-001',
            'location_id': 'loc-001',
            'grn_no': 'GRN-001',
            'grn_date': '2026-07-01',
            'supplier_id': 'sup-001',
            'supplier': {'account_code': 'SUP01', 'account_name': 'ABC Traders'},
            'receipt_mode': 'AGAINST_PO',
            'currency': {'currency_id': 'USD'},
            'grand_total': 1500.5,
            'status': 'APPROVED',
          }),
          GrnModel.fromJson(const {
            'id': 'grn-2',
            'client_id': 'client-001',
            'company_id': 'company-001',
            'location_id': 'loc-001',
            'grn_no': 'GRN-002',
            'grn_date': '2026-07-02',
            'supplier_id': 'sup-002',
            'receipt_mode': 'DIRECT',
            'grand_total': 0,
            'status': 'DRAFT',
          }),
        ]);

    await pumpApp(tester, const GrnListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('GRN-001'), findsOneWidget);
    expect(find.text('GRN-002'), findsOneWidget);
    expect(find.text('Against PO'), findsOneWidget);
    expect(find.text('Direct'), findsOneWidget);
    expect(find.text('[SUP01] ABC Traders'), findsOneWidget);
    // GRN-002 has no supplier embed at all — falls back to an em-dash.
    expect(find.text('—'), findsOneWidget);
    expect(find.text('USD 1500.50'), findsOneWidget);
    // GRN-002 has no currency embed, so the code is an empty string —
    // '${null ?? ''} ${0.00...}' leaves a leading space before the amount.
    expect(find.text(' 0.00'), findsOneWidget);
    // _statusLabel maps APPROVED/DRAFT to 'Approved'/'Draft' here, not
    // 'Posted' — this screen's own labels, unlike the Finance vouchers.
    expect(find.text('Approved'), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows the empty state when the page loads with zero GRNs', (tester) async {
    when(() => mockRepo.listGrns(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => []);

    await pumpApp(tester, const GrnListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('No goods receipts found'), findsOneWidget);
  });

  testWidgets('shows an error message when the repository throws', (tester) async {
    when(() => mockRepo.listGrns(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenThrow(Exception('connection refused'));

    await pumpApp(tester, const GrnListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    // Unlike the Finance voucher screens, this list screen predates the
    // ErrorPresenter rollout and still interpolates the raw exception
    // directly into its error text (`'Could not load goods receipts: $e'`)
    // — documented in CLAUDE.md as a known, not-yet-retrofitted gap. This
    // test asserts the CURRENT (imperfect) behavior, not the ideal one.
    expect(find.text('Could not load goods receipts: Exception: connection refused'), findsOneWidget);
  });
}
