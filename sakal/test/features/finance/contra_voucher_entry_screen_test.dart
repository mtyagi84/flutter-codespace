import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/layout/screen_header.dart';
import 'package:sakal/core/providers/master_cache_providers.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/core/widgets/sakal_field_card.dart';
import 'package:sakal/features/finance/data/models/finance_voucher_model.dart';
import 'package:sakal/features/finance/domain/repositories/finance_voucher_repository.dart';
import 'package:sakal/features/finance/presentation/providers/finance_voucher_providers.dart';
import 'package:sakal/features/finance/presentation/screens/contra_voucher_entry_screen.dart';

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

void main() {
  late MockFinanceVoucherRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
  });

  setUp(() {
    mockRepo = MockFinanceVoucherRepository();
  });

  // ContraVoucherEntryScreen's own _init() unconditionally Future.waits on
  // accountsProvider/baseCurrencyProvider/localCurrencyProvider — all have
  // to be overridden regardless of new-vs-edit mode, or the real provider
  // chain runs and hits DioClient/a real datasource. Unlike Journal
  // Voucher, this screen never reads currenciesProvider — trans_currency
  // is always the FROM account's own currency, there's no header Currency
  // dropdown.
  //
  // One Cash account + one Bank account, both same currency (USD) — keeps
  // the From/To reconciliation exact (gap == 0) so no Transfer Charge line
  // is ever required by the fixtures below.
  List<Override> overrides() => [
        financeVoucherRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
        accountsProvider.overrideWith((ref) async => [
              {
                'id': 'acc-cash',
                'account_code': 'CASH-01',
                'account_name': 'Petty Cash',
                'account_nature': 'Cash',
                'posting_allowed': true,
                'rim_currencies': {'currency_id': 'USD'},
              },
              {
                'id': 'acc-bank',
                'account_code': 'BANK-01',
                'account_name': 'Main Bank',
                'account_nature': 'Bank',
                'posting_allowed': true,
                'rim_currencies': {'currency_id': 'USD'},
              },
            ]),
        baseCurrencyProvider.overrideWith((ref) async => 'USD'),
        localCurrencyProvider.overrideWith((ref) async => 'FC'),
      ];

  group('New (blank) contra voucher', () {
    testWidgets('renders the blank form with From/To blocks and no post-save actions', (tester) async {
      await pumpApp(tester, const ContraVoucherEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      final header = _readHeader(tester, find.byType(ContraVoucherEntryScreen));
      expect(header?.title, 'New Contra Voucher');
      // Flavor subtitle — 'Contra Voucher' (generic) until both accounts are picked.
      expect(header?.subtitle, 'Contra Voucher');
      expect(header?.badgeText, 'Draft');

      expect(_findFieldLabel('VOUCHER NO'), findsOneWidget);
      expect(_findFieldLabel('VOUCHER DATE'), findsOneWidget);
      expect(_findFieldLabel('REFERENCE NO'), findsOneWidget);
      expect(_findFieldLabel('REFERENCE DATE'), findsOneWidget);

      // Two account blocks — From and To.
      expect(find.text('FROM'), findsOneWidget);
      expect(find.text('TO'), findsOneWidget);
      expect(_findFieldLabel('ACCOUNT'), findsNWidgets(2));
      expect(_findFieldLabel('CURRENCY'), findsNWidgets(2));
      // 'Amount' (From) and 'Amount Received' (To) both contain "AMOUNT".
      expect(_findFieldLabel('AMOUNT'), findsNWidgets(2));

      expect(_findFieldLabel('REMARKS'), findsOneWidget); // footer only, no line grid on this screen

      // No gap yet (no accounts/amounts entered) — charge section collapsed
      // to its "Add" prompt.
      expect(find.text('Add Transfer Charge (bank fee, courier charge, etc.)'), findsOneWidget);

      // Default test surface (~800 logical width) is >= Responsive's own
      // 600px mobile breakpoint (a NARROWER threshold than
      // SakalAdaptiveList's 1024px one) — this screen's own isMobile check
      // resolves false, so it renders the desktop Row/swap_horiz layout.
      expect(find.byIcon(Icons.swap_horiz), findsOneWidget);

      expect(find.text('Save Draft'), findsOneWidget);
      expect(header?.actions.length, 1); // Save Draft now shows in the desktop TopBar
      expect(find.text('Copy'), findsNothing);
      expect(find.text('Approve'), findsNothing);
      expect(find.text('Reverse'), findsNothing);
    });

    testWidgets('blocks save and shows a validation message when From/To accounts are not picked', (tester) async {
      await pumpApp(tester, const ContraVoucherEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      // _saveDraft() checks From/To accounts first, before amounts/gap.
      expect(find.text('Pick both a From and a To account.'), findsOneWidget);
      verifyNever(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            userId: any(named: 'userId'),
          ));
    });
  });

  group('Editing an existing DRAFT (resume flow, Cash → Bank deposit)', () {
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
            transNo: 'CTR-001',
            transDate: '2026-07-01',
            voucherTypeCode: 'CTR',
            paymentModeCode: '',
            isOnAccount: true,
            referenceNo: 'REF-200',
            referenceDate: '2026-07-01',
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
            // serial_no 1 = FROM (always CR).
            FinanceVoucherLine(
              serialNo: 1,
              accountId: 'acc-cash',
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
              lineRemarks: 'Deposit',
            ),
            // serial_no 2 = TO (always DR).
            FinanceVoucherLine(
              serialNo: 2,
              accountId: 'acc-bank',
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
              lineRemarks: 'Deposit',
            ),
          ]);
    }

    testWidgets('loads and displays every field from the saved header and From/To lines', (tester) async {
      stubExistingDraft();

      await pumpApp(
        tester,
        const ContraVoucherEntryScreen(editTransNo: 'CTR-001', editTransDate: '2026-07-01'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      final header = _readHeader(tester, find.byType(ContraVoucherEntryScreen));
      expect(header?.title, 'CTR-001');
      // fromNature=Cash, toNature=Bank ⇒ _flavorLabel == 'Deposit'.
      expect(header?.subtitle, 'Deposit');
      expect(header?.badgeText, 'Draft');
      // The read-only Voucher No field card's own value — the title itself
      // no longer renders as body text (moved to the TopBar via the header
      // provider, asserted above).
      expect(find.text('CTR-001'), findsOneWidget);

      expect(find.text('[CASH-01] Petty Cash'), findsOneWidget);
      expect(find.text('[BANK-01] Main Bank'), findsOneWidget);
      expect(find.text('USD'), findsNWidgets(2)); // From Currency + To Currency readonly fields
      // Contra's own _fmtNum trims to a bare integer string when there's no
      // fractional part — _trimZeros(1000.0) == '1000'.
      expect(find.text('1000'), findsNWidgets(2)); // From Amount + To Amount Received

      expect(find.text('Original remarks'), findsOneWidget);
      // No gap between From (1000) and To (1000) at a 1:1 same-currency
      // rate — charge section stays collapsed even on a resumed draft.
      expect(find.text('Add Transfer Charge (bank fee, courier charge, etc.)'), findsOneWidget);

      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.text('Approve'), findsNothing); // canApprove defaults false from the harness's empty menuProvider
      expect(header?.actions.length, 3); // Copy + Save Draft + Print all show in the desktop TopBar
      expect(find.text('Copy'), findsOneWidget); // a saved voucher can be copied
      expect(find.text('Reverse'), findsNothing); // only shown once posted
    });

    testWidgets('editing remarks and saving calls the repository with the From/To payload', (tester) async {
      stubExistingDraft();
      when(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'CTR-001');
      when(() => mockRepo.cacheVoucherLocally(
            effectiveTransNo: any(named: 'effectiveTransNo'),
            header: any(named: 'header'),
            lines: any(named: 'lines'),
          )).thenAnswer((_) async {});

      await pumpApp(
        tester,
        const ContraVoucherEntryScreen(editTransNo: 'CTR-001', editTransDate: '2026-07-01'),
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

      expect(header['trans_no'], 'CTR-001');
      expect(header['location_id'], 'loc-001');
      expect(header['voucher_type_code'], 'CTR');
      expect(header['is_on_account'], true);
      expect(header['reference_no'], 'REF-200');
      expect(header['reference_date'], '2026-07-01');
      expect(header['remarks'], 'Updated remarks');

      // No gap (From 1000 == To 1000 at same currency) ⇒ no third
      // Transfer Charge line gets appended.
      expect(lines, hasLength(2));

      final fromLine = lines[0];
      expect(fromLine['serial_no'], 1);
      expect(fromLine['account_id'], 'acc-cash');
      expect(fromLine['trans_nature'], 'CR');
      expect(fromLine['trans_amount'], 1000.0);
      expect(fromLine['trans_currency'], 'USD');
      expect(fromLine['base_amount'], 1000.0);
      expect(fromLine['base_rate'], 1.0);
      expect(fromLine['local_amount'], 1000.0);
      expect(fromLine['local_rate'], 1.0);
      expect(fromLine['party_amount'], 1000.0);
      expect(fromLine['party_currency'], 'USD');
      expect(fromLine['party_rate'], 1);
      expect(fromLine['line_remarks'], 'Deposit'); // _flavorLabel, recomputed at save time

      final toLine = lines[1];
      expect(toLine['serial_no'], 2);
      expect(toLine['account_id'], 'acc-bank');
      expect(toLine['trans_nature'], 'DR');
      expect(toLine['trans_amount'], 1000.0); // _toTransAmount — same currency ⇒ equals amount entered
      expect(toLine['trans_currency'], 'USD'); // always the FROM account's currency
      expect(toLine['base_amount'], 1000.0);
      expect(toLine['local_amount'], 1000.0);
      expect(toLine['party_amount'], 1000.0);
      expect(toLine['party_currency'], 'USD');
      expect(toLine['line_remarks'], 'Deposit');

      expect(find.text('Contra Voucher CTR-001 saved.'), findsOneWidget);
    });
  });

  // Contra Voucher's own FROM/TO account pickers are each a
  // FinanceAccountPicker instance (unlike Journal Voucher's line grid, this
  // screen has exactly one FROM block and one TO block, built by the same
  // _buildAccountBlock() helper) — driven here the same way as JV's own
  // pilot above: type a partial name, tap the rendered option (rendered as
  // separate Code/Name/Parent Text widgets, not one combined string), and
  // confirm the field's own combined text updates afterward.
  group('FROM account picker interaction (real search + select)', () {
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

    testWidgets('typing into the FROM Account field shows the matching option, and selecting it fills the field and Currency',
        (tester) async {
      // _onFromSelected always calls _refreshBaseLocalRates(), which fetches
      // the LOCAL rate (fromCurrency→FC) unconditionally once the two
      // differ — this fixture's fromCurrency ('USD') equals baseCcy so the
      // BASE-rate half short-circuits, but localCcy ('FC') differs, so a
      // real repository call happens and needs a stub.
      when(() => mockRepo.fetchExchangeRate(
            companyId: any(named: 'companyId'),
            locationId: any(named: 'locationId'),
            fromCurrency: any(named: 'fromCurrency'),
            toCurrency: any(named: 'toCurrency'),
            rateDate: any(named: 'rateDate'),
          )).thenAnswer((_) async => 1.0);

      await pumpApp(tester, const ContraVoucherEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      // Two "Account" fields exist on this screen (FROM block, then TO
      // block, in that widget-tree order) — .first resolves to the FROM
      // block's own, since _buildTransferRow() builds fromBlock before
      // toBlock.
      final fromAccountField = fieldInCard('Account', () => find.byType(TextFormField));
      await tester.enterText(fromAccountField, 'Petty');
      await tester.pumpAndSettle();

      expect(find.text('Petty Cash'), findsOneWidget);

      await tester.tap(find.text('Petty Cash'));
      // FinanceAccountPicker here is built with `key: ValueKey(accountDisplay)`
      // (see _buildAccountBlock) — selecting changes _fromAccountDisplay,
      // forcing a remount; pumpAndSettle lets that finish.
      await tester.pumpAndSettle();

      // _onFromSelected sets _fromAccountId/_fromAccountDisplay/_fromCurrency
      // — the field's own displayed text and the FROM block's own readonly
      // Currency field (from '—' to 'USD') are the simplest observable
      // proof the selection landed. The TO block's own Currency field is
      // still unselected ('—'), so 'USD' stays unique.
      expect(find.text('[CASH-01] Petty Cash'), findsOneWidget);
      expect(find.text('USD'), findsOneWidget);
    });
  });
}
