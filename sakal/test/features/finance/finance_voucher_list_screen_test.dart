import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/models/menu_models.dart';
import 'package:sakal/core/providers/session_provider.dart';
import 'package:sakal/core/router/route_names.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/features/finance/data/models/finance_voucher_model.dart';
import 'package:sakal/features/finance/domain/repositories/finance_voucher_repository.dart';
import 'package:sakal/features/finance/presentation/providers/finance_voucher_providers.dart';
import 'package:sakal/features/finance/presentation/screens/finance_voucher_list_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockFinanceVoucherRepository extends Mock implements FinanceVoucherRepository {}

// FinanceVoucherListScreen is the one screen in this batch that does NOT use
// ScreenPermissionMixin — it reads menuProvider directly via its own private
// _findFeature() helper and shows a "no access" lock screen when the screen
// isn't found in the menu list. pump_app.dart's default empty menuProvider
// (deliberately left that way for ScreenPermissionMixin-based screens) would
// make every test here render the lock screen instead of the real content,
// so this file supplies its own menuProvider override.
List<Override> _menuOverride() => [
      menuProvider.overrideWith((ref) => [
            const MenuModule(
              moduleCode: 'FIN',
              moduleName: 'Finance',
              serialNo: 1,
              groups: [
                MenuGroup(
                  groupCode: 'FIN-VCH',
                  groupName: 'Vouchers',
                  serialNo: 1,
                  features: [
                    MenuFeature(
                      featureCode: 'FN-PRV',
                      featureName: 'Payment/Receipt Voucher',
                      screenName: RouteNames.voucherList,
                      serialNo: 1,
                      addAllowed: true,
                      editAllowed: true,
                      approveAllowed: true,
                      copyAllowed: false,
                      excelUploadAllowed: false,
                    ),
                  ],
                ),
              ],
            ),
          ]),
    ];

void main() {
  late MockFinanceVoucherRepository mockRepo;

  setUp(() {
    mockRepo = MockFinanceVoucherRepository();
  });

  // Built fresh inside each test — see journal_voucher_list_screen_test.dart's
  // comment: mockRepo is only assigned once setUp() runs before each test, so
  // building this list at the top of main() throws LateError.
  List<Override> overrides() => [
        financeVoucherRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
        ..._menuOverride(),
      ];

  testWidgets('shows a loading indicator before the first page resolves', (tester) async {
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

    await pumpApp(tester, const FinanceVoucherListScreen(), overrides: overrides(), session: testSession());
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
            'trans_no': 'FVL-001',
            'trans_date': '2026-07-01',
            'voucher_type_code': 'CRV',
            'payment_mode_code': 'CASH',
            'is_on_account': true,
            'is_posted': true,
            'remarks': 'Rent received',
          }),
          FinanceVoucherHeader.fromJson(const {
            'trans_no': 'FVL-002',
            'trans_date': '2026-07-02',
            'voucher_type_code': 'BPV',
            'payment_mode_code': '',
            'is_on_account': false,
            'is_posted': false,
            'remarks': '',
          }),
        ]);

    await pumpApp(tester, const FinanceVoucherListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('FVL-001'), findsOneWidget);
    expect(find.text('FVL-002'), findsOneWidget);
    expect(find.text('Cash Receipt'), findsOneWidget);
    expect(find.text('Bank Payment'), findsOneWidget);
    expect(find.text('On Account'), findsOneWidget);
    expect(find.text('Against Bill'), findsOneWidget);
    expect(find.text('Rent received'), findsOneWidget);
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

    await pumpApp(tester, const FinanceVoucherListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('No vouchers found'), findsOneWidget);
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

    await pumpApp(tester, const FinanceVoucherListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    // This screen predates ErrorPresenter's rollout and still uses a
    // hardcoded message rather than ErrorPresenter.format() — see
    // finance_voucher_list_screen.dart's own _load() catch block.
    expect(find.text('Could not load vouchers.'), findsOneWidget);
    expect(find.textContaining('connection refused'), findsNothing);
  });
}
