import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/features/purchase/data/models/purchase_return_model.dart';
import 'package:sakal/features/purchase/domain/repositories/purchase_return_repository.dart';
import 'package:sakal/features/purchase/presentation/providers/purchase_return_providers.dart';
import 'package:sakal/features/purchase/presentation/screens/purchase_return_list_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockPurchaseReturnRepository extends Mock implements PurchaseReturnRepository {}

void main() {
  late MockPurchaseReturnRepository mockRepo;

  setUp(() {
    mockRepo = MockPurchaseReturnRepository();
  });

  // Built fresh inside each test — see journal_voucher_list_screen_test.dart's
  // comment: mockRepo is only assigned once setUp() runs before each test, so
  // building this list at the top of main() throws LateError.
  List<Override> overrides() => [
        purchaseReturnRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  testWidgets('shows a loading indicator before the first page resolves', (tester) async {
    when(() => mockRepo.listPurchaseReturns(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) => Completer<List<PurchaseReturnModel>>().future);

    await pumpApp(tester, const PurchaseReturnListScreen(), overrides: overrides(), session: testSession());
    await tester.pump(); // let initState's postFrameCallback fire and _load() start

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders a row per return once the page loads', (tester) async {
    when(() => mockRepo.listPurchaseReturns(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => [
          PurchaseReturnModel.fromJson(const {
            'id': 'pret-1',
            'client_id': 'client-001',
            'company_id': 'company-001',
            'location_id': 'loc-001',
            'return_no': 'PRET-001',
            'return_date': '2026-07-01',
            'supplier_id': 'sup-001',
            'supplier': {'account_code': 'SUP01', 'account_name': 'ABC Traders'},
            'reason': 'Damaged goods',
            'currency': {'currency_id': 'USD'},
            'return_total': 450.25,
            'status': 'APPROVED',
          }),
          PurchaseReturnModel.fromJson(const {
            'id': 'pret-2',
            'client_id': 'client-001',
            'company_id': 'company-001',
            'location_id': 'loc-001',
            'return_no': 'PRET-002',
            'return_date': '2026-07-02',
            'supplier_id': 'sup-002',
            'return_total': 0,
            'status': 'DRAFT',
          }),
        ]);

    await pumpApp(tester, const PurchaseReturnListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('PRET-001'), findsOneWidget);
    expect(find.text('PRET-002'), findsOneWidget);
    expect(find.text('Damaged goods · 01 Jul 2026'), findsOneWidget);
    // Return 2 has no reason — the combined "reason · date" line falls back
    // to an em-dash for the reason half, but stays a single distinct string.
    expect(find.text('— · 02 Jul 2026'), findsOneWidget);
    expect(find.text('[SUP01] ABC Traders'), findsOneWidget);
    // Return 2 has no supplier embed at all — its OWN supplier-name Text
    // falls back to a bare em-dash (separate widget from the line above).
    expect(find.text('—'), findsOneWidget);
    expect(find.text('USD 450.25'), findsOneWidget);
    // Return 2 has no currency embed, so the code is an empty string —
    // '${null ?? ''} ${0.00...}' leaves a leading space before the amount.
    expect(find.text(' 0.00'), findsOneWidget);
    expect(find.text('Approved'), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows the empty state when the page loads with zero returns', (tester) async {
    when(() => mockRepo.listPurchaseReturns(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => []);

    await pumpApp(tester, const PurchaseReturnListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('No purchase returns found'), findsOneWidget);
  });

  testWidgets('shows an error message when the repository throws', (tester) async {
    when(() => mockRepo.listPurchaseReturns(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenThrow(Exception('connection refused'));

    await pumpApp(tester, const PurchaseReturnListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    // This screen predates the ErrorPresenter rollout and still interpolates
    // the raw exception directly (`'Could not load purchase returns: $e'`) —
    // this test asserts the CURRENT behavior, not the ideal one.
    expect(find.text('Could not load purchase returns: Exception: connection refused'), findsOneWidget);
  });
}
