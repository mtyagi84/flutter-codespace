import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/layout/screen_header.dart';
import 'package:sakal/core/models/menu_models.dart';
import 'package:sakal/core/providers/master_cache_providers.dart';
import 'package:sakal/core/providers/session_provider.dart';
import 'package:sakal/core/router/route_names.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/core/widgets/sakal_field_card.dart';
import 'package:sakal/features/finance/data/models/finance_voucher_model.dart';
import 'package:sakal/features/finance/domain/repositories/finance_voucher_repository.dart';
import 'package:sakal/features/finance/presentation/providers/finance_voucher_providers.dart';
import 'package:sakal/features/finance/presentation/screens/finance_voucher_entry_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockFinanceVoucherRepository extends Mock implements FinanceVoucherRepository {}

class _FakeStringDynamicMap extends Fake implements Map<String, dynamic> {}
class _FakeStringDynamicMapList extends Fake implements List<Map<String, dynamic>> {}

Future<void> _pumpBriefly(WidgetTester tester, {int times = 5}) async {
  for (var i = 0; i < times; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// SakalFieldCard renders its label as a raw RichText, not wrapped in
/// Text/Text.rich — find.text()/find.textContaining() don't reliably match
/// a bare RichText, so match directly against the TextSpan's own plain text.
Finder _findFieldLabel(String label) => find.byWidgetPredicate(
      (w) => w is RichText && w.maxLines == 1 && w.text.toPlainText().toUpperCase().contains(label.toUpperCase()),
    );

/// The screen's title/subtitle/badge no longer render as body text — they're
/// posted to the shared TopBar via ScreenHeaderMixin (screen_header.dart),
/// and pumpApp() doesn't include a TopBar in its pumped tree at all. Read
/// the posted ScreenHeaderInfo back from the provider instead of searching
/// for rendered text — this is the actual observable contract the screen
/// provides now.
ScreenHeaderInfo? _readHeader(WidgetTester tester, Finder screenFinder) =>
    ProviderScope.containerOf(tester.element(screenFinder)).read(screenHeaderProvider);

// FinanceVoucherEntryScreen is one of the screens that does NOT use
// ScreenPermissionMixin — it reads menuProvider directly via its own
// private, module-level _findFeature() helper and renders a "You do not
// have access to this screen." lock screen entirely (not just disabled
// buttons) when the screen isn't found in the menu list. pump_app.dart's
// default empty menuProvider (deliberately left that way for
// ScreenPermissionMixin-based screens) would make every test here render
// the lock screen instead of the real form, so this file supplies its own
// menuProvider override — same gotcha already documented and fixed in
// finance_voucher_list_screen_test.dart for the sibling list screen.
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
                      approveAllowed: false,
                      copyAllowed: true,
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

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
  });

  setUp(() {
    mockRepo = MockFinanceVoucherRepository();
  });

  // FinanceVoucherEntryScreen's own _init() always Future.waits on
  // paymentModesProvider/baseCurrencyProvider/localCurrencyProvider (in
  // addition to accountsProvider) regardless of new-vs-edit mode, since
  // session.offlineMode is false in every test session here.
  List<Override> overrides() => [
        financeVoucherRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
        accountsProvider.overrideWith((ref) async => [
              {
                'id': 'cash-001',
                'account_code': 'CASH-01',
                'account_name': 'Cash In Hand',
                'account_nature': 'Cash',
                'posting_allowed': true,
                'rim_currencies': {'currency_id': 'USD'},
              },
              {
                'id': 'acc-001',
                'account_code': 'INC-01',
                'account_name': 'Sales Income',
                'account_nature': 'Income',
                'posting_allowed': true,
                'rim_currencies': {'currency_id': 'USD'},
              },
              {
                'id': 'cust-001',
                'account_code': 'CUS-01',
                'account_name': 'Test Customer',
                'account_nature': 'Customer',
                'posting_allowed': true,
                'rim_currencies': {'currency_id': 'USD'},
              },
            ]),
        baseCurrencyProvider.overrideWith((ref) async => 'USD'),
        localCurrencyProvider.overrideWith((ref) async => 'FC'),
        paymentModesProvider.overrideWith((ref) async => [
              {'payment_mode_code': 'CASH', 'payment_mode_name': 'Cash'},
            ]),
        ..._menuOverride(),
      ];

  group('New (blank) Cash Receipt Voucher', () {
    testWidgets('renders the blank CRV form with all key fields and no print/copy/approve buttons', (tester) async {
      await pumpApp(
        tester,
        const FinanceVoucherEntryScreen(initialVoucherType: 'CRV'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      final header = _readHeader(tester, find.byType(FinanceVoucherEntryScreen));
      expect(header?.title, 'New Cash Receipt Voucher');
      expect(header?.subtitle, 'Unsaved draft');

      expect(_findFieldLabel('VOUCHER TYPE'), findsOneWidget);
      expect(_findFieldLabel('VOUCHER NO'), findsOneWidget);
      expect(_findFieldLabel('CASH ACCOUNT'), findsOneWidget); // CRV → isCashVoucher → 'Cash Account'
      expect(_findFieldLabel('CURRENCY'), findsOneWidget);
      expect(_findFieldLabel('RATE'), findsOneWidget); // showRateField false → plain 'Rate' label
      expect(_findFieldLabel('PAYMENT MODE'), findsOneWidget);
      expect(_findFieldLabel('REF NO'), findsOneWidget);
      expect(_findFieldLabel('REF DATE'), findsOneWidget);
      expect(_findFieldLabel('REMARKS'), findsOneWidget);
      // Against Bill is the default mode; CRV is a receipt voucher → party field labeled 'Customer'.
      expect(_findFieldLabel('CUSTOMER *'), findsOneWidget);

      expect(find.text('(auto on save)'), findsOneWidget); // Voucher No read-only placeholder
      expect(find.text('Against Bill'), findsOneWidget);
      expect(find.text('On Account'), findsOneWidget);
      expect(find.text('Select a customer or supplier to see pending bills.'), findsOneWidget);

      expect(find.text('Total: '), findsOneWidget);
      expect(find.text('0.00 USD'), findsOneWidget);
      expect(find.text('Enter amounts'), findsOneWidget);

      expect(find.text('Save Draft'), findsOneWidget);
      // A brand-new, never-saved voucher has no voucher number yet, so no
      // copy button, no print button, and no post/approve button.
      expect(find.byIcon(Icons.copy_outlined), findsNothing);
      expect(header?.actions.length, 1); // Save Draft now shows in the desktop TopBar
      expect(find.text('Post Voucher'), findsNothing);
    });

    testWidgets('blocks save and shows a validation message when no cash account is selected', (tester) async {
      await pumpApp(
        tester,
        const FinanceVoucherEntryScreen(initialVoucherType: 'CRV'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      // _saveDraft() checks voucher type first (already set here), then the
      // cash/bank account — which is still unselected on a blank form.
      expect(find.text('Select a cash / bank account.'), findsOneWidget);
      verifyNever(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            userId: any(named: 'userId'),
          ));
    });
  });

  group('Editing an existing DRAFT (resume flow, On Account mode)', () {
    void stubExistingDraft() {
      when(() => mockRepo.getHeader(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            transNo: any(named: 'transNo'),
            transDate: any(named: 'transDate'),
          )).thenAnswer((_) async => const FinanceVoucherHeader(
            clientId: 'client-001',
            companyId: 'company-001',
            locationId: 'loc-001',
            transNo: 'CRV-001',
            transDate: '2026-07-01',
            voucherTypeCode: 'CRV',
            paymentModeCode: 'CASH',
            isOnAccount: true,
            referenceNo: 'REF-1',
            referenceDate: '',
            chequeNo: '',
            chequeDate: '',
            remarks: 'Original remarks',
            isPosted: false,
            isDeleted: false,
            createdByName: 'Test User',
            postedByName: '',
          ));
      when(() => mockRepo.getLines(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            transNo: any(named: 'transNo'),
            transDate: any(named: 'transDate'),
          )).thenAnswer((_) async => const [
            FinanceVoucherLine(
              serialNo: 1,
              accountId: 'cash-001',
              transNature: 'DR',
              transAmount: 1000,
              transCurrency: 'USD',
              baseAmount: 1000,
              baseRate: 1,
              localAmount: 1000,
              localRate: 1,
              partyAmount: 1000,
              partyCurrency: 'USD',
              partyRate: 1,
              invBillNo: '',
              invBillDate: '',
              lineRemarks: '',
            ),
            FinanceVoucherLine(
              serialNo: 2,
              accountId: 'acc-001',
              transNature: 'CR',
              transAmount: 1000,
              transCurrency: 'USD',
              baseAmount: 1000,
              baseRate: 1,
              localAmount: 1000,
              localRate: 1,
              partyAmount: 1000,
              partyCurrency: 'USD',
              partyRate: 1,
              invBillNo: '',
              invBillDate: '',
              lineRemarks: 'Line remark A',
            ),
          ]);
    }

    testWidgets('loads and displays every field from the saved header and on-account lines', (tester) async {
      stubExistingDraft();

      await pumpApp(
        tester,
        const FinanceVoucherEntryScreen(editTransNo: 'CRV-001', editTransDate: '2026-07-01'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      final header = _readHeader(tester, find.byType(FinanceVoucherEntryScreen));
      expect(header?.title, 'Cash Receipt Voucher  ·  CRV-001');
      expect(header?.subtitle, 'Draft'); // not posted, voucherNo != null ⇒ subtitle 'Draft' (not badgeText)
      expect(find.text('[CASH-01] Cash In Hand'), findsOneWidget); // Cash account autocomplete field text
      expect(find.text('USD'), findsOneWidget); // Currency read-only field
      expect(find.text('01 Jul 2026'), findsOneWidget); // Date field
      expect(find.text('REF-1'), findsOneWidget); // Ref No field
      expect(find.text('Original remarks'), findsOneWidget); // header Remarks field

      // On Account section — n2 = counterNature(line1Nature('CRV')) = 'CR' → verb = 'Credit'.
      expect(find.text('Credit Accounts'), findsOneWidget);
      expect(find.text('Sales Income'), findsOneWidget); // line card title (line.accountName)
      expect(find.text('[INC-01] Sales Income'), findsOneWidget); // account autocomplete field text
      expect(find.text('1000.0'), findsOneWidget); // amountCtrl set via row.transAmount.toString()
      expect(find.text('Line remark A'), findsOneWidget);

      expect(find.text('1,000.00 USD'), findsOneWidget); // totals bar
      expect(find.text('Balanced'), findsOneWidget);

      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.text('Post Voucher'), findsNothing); // approveAllowed=false in this fixture
      expect(header?.actions.length, 3); // Copy + Save Draft + Print all show in the desktop TopBar
      expect(find.byIcon(Icons.copy_outlined), findsOneWidget); // saved + On Account → copy allowed
    });

    testWidgets('editing remarks and saving calls the repository with the updated payload', (tester) async {
      stubExistingDraft();
      when(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'CRV-001');
      when(() => mockRepo.cacheVoucherLocally(
            effectiveTransNo: any(named: 'effectiveTransNo'),
            header: any(named: 'header'),
            lines: any(named: 'lines'),
          )).thenAnswer((_) async {});

      await pumpApp(
        tester,
        const FinanceVoucherEntryScreen(editTransNo: 'CRV-001', editTransDate: '2026-07-01'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.text('Original remarks'), 'Updated remarks');
      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      final captured = verify(() => mockRepo.save(
            header: captureAny(named: 'header'),
            lines: captureAny(named: 'lines'),
            userId: any(named: 'userId'),
          )).captured;
      final header = captured[0] as Map<String, dynamic>;
      final lines = captured[1] as List<Map<String, dynamic>>;

      expect(header['trans_no'], 'CRV-001');
      expect(header['trans_date'], '2026-07-01');
      expect(header['voucher_type_code'], 'CRV');
      expect(header['payment_mode_code'], 'CASH');
      expect(header['is_on_account'], true);
      expect(header['reference_no'], 'REF-1');
      expect(header['cheque_no'], '');
      expect(header['remarks'], 'Updated remarks');

      expect(lines, hasLength(2));

      final cashLine = lines[0];
      expect(cashLine['serial_no'], 1);
      expect(cashLine['account_id'], 'cash-001');
      expect(cashLine['trans_nature'], 'DR');
      expect(cashLine['trans_amount'], 1000.0);
      expect(cashLine['trans_currency'], 'USD');
      expect(cashLine['base_amount'], 1000.0);
      expect(cashLine['base_rate'], 1.0);
      expect(cashLine['party_amount'], 1000.0);
      expect(cashLine['party_currency'], 'USD');

      final acctLine = lines[1];
      expect(acctLine['serial_no'], 2);
      expect(acctLine['account_id'], 'acc-001');
      expect(acctLine['trans_nature'], 'CR');
      expect(acctLine['trans_amount'], 1000.0);
      expect(acctLine['party_amount'], 1000.0);
      expect(acctLine['party_currency'], 'USD');
      expect(acctLine['line_remarks'], 'Line remark A');

      expect(find.text('Draft saved — CRV-001'), findsOneWidget);
    });
  });

  // Every prior test in this file deliberately excluded driving this
  // screen's own account pickers through real user interaction. Unlike
  // Journal/Contra/Expense Voucher (all built on the shared
  // FinanceAccountPicker), this screen's own `_buildAccountSearch()`
  // helper is a raw SakalAutocomplete with its own bespoke optionBuilder
  // (Column of [combined "[code] name" Text, optional parent-name
  // subtitle Text]) — the fixture accounts here carry no 'parent' key, so
  // only the FIRST Text renders per option, and it already IS the full
  // combined display string. That makes the overlay assertion below match
  // GRN's own pilot shape (a single find.text() for the whole string),
  // not Journal/Contra Voucher's split-into-three-Texts shape — confirmed
  // by reading _buildAccountSearch's optionBuilder directly, not assumed.
  group('Cash Account + Customer picker interaction (real search + select)', () {
    Finder fieldInCard(String label, Finder Function() matcher) => find.descendant(
          of: find.ancestor(
                of: find.byWidgetPredicate((w) =>
                    w is RichText &&
                    (w.text.toPlainText().trim().toUpperCase() == label.toUpperCase() ||
                        w.text.toPlainText().trim().toUpperCase() == '${label.toUpperCase()} *')),
                matching: find.byType(SakalFieldCard),
              ).first,
          matching: matcher(),
        );

    testWidgets('typing into the Cash Account field shows the matching option, and selecting it fills the field and Currency',
        (tester) async {
      // _onCashBankSelected always calls _fetchRatesForTrans(), which
      // fetches the LOCAL rate (trans→FC) unconditionally once the trans
      // and local currencies differ — this fixture's local currency ('FC')
      // differs from trans ('USD' once selected), so a real repository
      // call happens and needs a stub (unlike Journal Voucher's own
      // fixture, where accountCurrency == baseCcy short-circuits it).
      when(() => mockRepo.fetchExchangeRate(
            companyId: any(named: 'companyId'),
            locationId: any(named: 'locationId'),
            fromCurrency: any(named: 'fromCurrency'),
            toCurrency: any(named: 'toCurrency'),
            rateDate: any(named: 'rateDate'),
          )).thenAnswer((_) async => 1.0);

      await pumpApp(
        tester,
        const FinanceVoucherEntryScreen(initialVoucherType: 'CRV'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      final cashAccountField = fieldInCard('Cash Account', () => find.byType(TextFormField));
      await tester.enterText(cashAccountField, 'Cash');
      await tester.pumpAndSettle();

      expect(find.text('[CASH-01] Cash In Hand'), findsOneWidget);

      await tester.tap(find.text('[CASH-01] Cash In Hand'));
      // _buildAccountSearch's SakalAutocomplete carries `key:
      // ValueKey(keyValue ?? selectedId ?? 'none')` — selecting changes
      // _cashBankId, forcing a remount; pumpAndSettle lets that finish.
      await tester.pumpAndSettle();

      // _onCashBankSelected sets _cashBankId/_transCurrency — the field's
      // own displayed text plus the readonly Currency field (from '—' to
      // 'USD') are the simplest observable proof the selection landed.
      expect(find.text('[CASH-01] Cash In Hand'), findsOneWidget);
      expect(find.text('USD'), findsOneWidget);
    });

    testWidgets('typing into the Customer field shows the matching option, and selecting it loads pending bills for that party',
        (tester) async {
      when(() => mockRepo.getPendingBills(
            companyId: any(named: 'companyId'),
            locationId: any(named: 'locationId'),
            accountId: any(named: 'accountId'),
          )).thenAnswer((_) async => []);

      await pumpApp(
        tester,
        const FinanceVoucherEntryScreen(initialVoucherType: 'CRV'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      // Against Bill is the default mode for a brand-new voucher; CRV is a
      // receipt voucher, so the party field is labeled 'Customer' (already
      // confirmed by the existing blank-form test above).
      final customerField = fieldInCard('Customer', () => find.byType(TextFormField));
      await tester.enterText(customerField, 'Test');
      await tester.pumpAndSettle();

      expect(find.text('[CUS-01] Test Customer'), findsOneWidget);

      await tester.tap(find.text('[CUS-01] Test Customer'));
      await tester.pumpAndSettle();

      // _onPartySelected sets _partyId/_partyName and (since !_isOnAccount
      // by default) calls _loadPendingBills() — trans and party currency
      // both resolve to 'USD' here (no cash account picked in this test),
      // so _fetchCrossRate short-circuits with no fetchExchangeRate stub
      // needed. No bills configured in this fixture, so the empty-bills
      // message is the simplest observable proof the whole pick→fetch
      // chain actually ran, not just the field text.
      expect(find.text('[CUS-01] Test Customer'), findsOneWidget);
      expect(find.text('No pending bills found for this party.'), findsOneWidget);
    });
  });

  // Every prior test in this file exercised CRV (Cash Receipt Voucher) only.
  // This group closes that gap for the 3 remaining voucher types this same
  // screen renders — BRV/CPV/BPV — confirming lib/core/utils/voucher_logic.dart's
  // isCashVoucher/isBankVoucher/isReceiptVoucher branches actually drive the
  // right on-screen field labels/title, not just their own unit tests.
  // Deliberately lighter-weight than the CRV group above: one blank-form
  // render test per type (mirroring the existing CRV blank-form test's shape
  // exactly), not a full resume/save test per type. Label mapping confirmed
  // directly from the screen source, not assumed:
  //   _typeLabels: CRV 'Cash Receipt Voucher', BRV 'Bank Receipt Voucher',
  //                CPV 'Cash Payment Voucher', BPV 'Bank Payment Voucher'
  //   isCashVoucher (CRV/CPV) -> 'Cash Account' label on the line-1 field
  //   isBankVoucher (BRV/BPV) -> 'Bank Account' label on the line-1 field
  //   isReceiptVoucher (CRV/BRV) -> party field labeled 'Customer'
  //   !isReceiptVoucher (CPV/BPV) -> party field labeled 'Supplier'
  group('BRV / CPV / BPV blank-form render (remaining voucher-type branches)', () {
    testWidgets('renders the blank BRV form with Bank Account + Customer labels and the Bank Receipt Voucher title', (tester) async {
      await pumpApp(
        tester,
        const FinanceVoucherEntryScreen(initialVoucherType: 'BRV'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      final header = _readHeader(tester, find.byType(FinanceVoucherEntryScreen));
      expect(header?.title, 'New Bank Receipt Voucher');
      expect(header?.subtitle, 'Unsaved draft');

      expect(_findFieldLabel('VOUCHER TYPE'), findsOneWidget);
      expect(_findFieldLabel('VOUCHER NO'), findsOneWidget);
      expect(_findFieldLabel('BANK ACCOUNT'), findsOneWidget); // BRV → isBankVoucher → 'Bank Account'
      expect(_findFieldLabel('CURRENCY'), findsOneWidget);
      expect(_findFieldLabel('RATE'), findsOneWidget);
      expect(_findFieldLabel('PAYMENT MODE'), findsOneWidget);
      expect(_findFieldLabel('REF NO'), findsOneWidget);
      expect(_findFieldLabel('REF DATE'), findsOneWidget);
      expect(_findFieldLabel('REMARKS'), findsOneWidget);
      // BRV is a receipt voucher (isReceiptVoucher → true) → party field labeled 'Customer', same as CRV.
      expect(_findFieldLabel('CUSTOMER *'), findsOneWidget);

      expect(find.text('(auto on save)'), findsOneWidget);
      expect(find.text('Against Bill'), findsOneWidget);
      expect(find.text('On Account'), findsOneWidget);
      expect(find.text('Select a customer or supplier to see pending bills.'), findsOneWidget);

      expect(find.text('Total: '), findsOneWidget);
      expect(find.text('0.00 USD'), findsOneWidget);
      expect(find.text('Enter amounts'), findsOneWidget);

      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.byIcon(Icons.copy_outlined), findsNothing);
      expect(header?.actions.length, 1); // Save Draft now shows in the desktop TopBar
      expect(find.text('Post Voucher'), findsNothing);
    });

    testWidgets('renders the blank CPV form with Cash Account + Supplier labels and the Cash Payment Voucher title', (tester) async {
      await pumpApp(
        tester,
        const FinanceVoucherEntryScreen(initialVoucherType: 'CPV'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      final header = _readHeader(tester, find.byType(FinanceVoucherEntryScreen));
      expect(header?.title, 'New Cash Payment Voucher');
      expect(header?.subtitle, 'Unsaved draft');

      expect(_findFieldLabel('VOUCHER TYPE'), findsOneWidget);
      expect(_findFieldLabel('VOUCHER NO'), findsOneWidget);
      expect(_findFieldLabel('CASH ACCOUNT'), findsOneWidget); // CPV → isCashVoucher → 'Cash Account'
      expect(_findFieldLabel('CURRENCY'), findsOneWidget);
      expect(_findFieldLabel('RATE'), findsOneWidget);
      expect(_findFieldLabel('PAYMENT MODE'), findsOneWidget);
      expect(_findFieldLabel('REF NO'), findsOneWidget);
      expect(_findFieldLabel('REF DATE'), findsOneWidget);
      expect(_findFieldLabel('REMARKS'), findsOneWidget);
      // CPV is a payment voucher (isReceiptVoucher → false) → party field labeled 'Supplier'.
      expect(_findFieldLabel('SUPPLIER *'), findsOneWidget);

      expect(find.text('(auto on save)'), findsOneWidget);
      expect(find.text('Against Bill'), findsOneWidget);
      expect(find.text('On Account'), findsOneWidget);
      expect(find.text('Select a customer or supplier to see pending bills.'), findsOneWidget);

      expect(find.text('Total: '), findsOneWidget);
      expect(find.text('0.00 USD'), findsOneWidget);
      expect(find.text('Enter amounts'), findsOneWidget);

      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.byIcon(Icons.copy_outlined), findsNothing);
      expect(header?.actions.length, 1); // Save Draft now shows in the desktop TopBar
      expect(find.text('Post Voucher'), findsNothing);
    });

    testWidgets('renders the blank BPV form with Bank Account + Supplier labels and the Bank Payment Voucher title', (tester) async {
      await pumpApp(
        tester,
        const FinanceVoucherEntryScreen(initialVoucherType: 'BPV'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      final header = _readHeader(tester, find.byType(FinanceVoucherEntryScreen));
      expect(header?.title, 'New Bank Payment Voucher');
      expect(header?.subtitle, 'Unsaved draft');

      expect(_findFieldLabel('VOUCHER TYPE'), findsOneWidget);
      expect(_findFieldLabel('VOUCHER NO'), findsOneWidget);
      expect(_findFieldLabel('BANK ACCOUNT'), findsOneWidget); // BPV → isBankVoucher → 'Bank Account'
      expect(_findFieldLabel('CURRENCY'), findsOneWidget);
      expect(_findFieldLabel('RATE'), findsOneWidget);
      expect(_findFieldLabel('PAYMENT MODE'), findsOneWidget);
      expect(_findFieldLabel('REF NO'), findsOneWidget);
      expect(_findFieldLabel('REF DATE'), findsOneWidget);
      expect(_findFieldLabel('REMARKS'), findsOneWidget);
      // BPV is a payment voucher (isReceiptVoucher → false) → party field labeled 'Supplier'.
      expect(_findFieldLabel('SUPPLIER *'), findsOneWidget);

      expect(find.text('(auto on save)'), findsOneWidget);
      expect(find.text('Against Bill'), findsOneWidget);
      expect(find.text('On Account'), findsOneWidget);
      expect(find.text('Select a customer or supplier to see pending bills.'), findsOneWidget);

      expect(find.text('Total: '), findsOneWidget);
      expect(find.text('0.00 USD'), findsOneWidget);
      expect(find.text('Enter amounts'), findsOneWidget);

      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.byIcon(Icons.copy_outlined), findsNothing);
      expect(header?.actions.length, 1); // Save Draft now shows in the desktop TopBar
      expect(find.text('Post Voucher'), findsNothing);
    });
  });
}
