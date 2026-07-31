import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/providers/master_cache_providers.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/core/widgets/sakal_field_card.dart';
import 'package:sakal/features/finance/data/models/finance_voucher_model.dart';
import 'package:sakal/features/finance/domain/repositories/finance_voucher_repository.dart';
import 'package:sakal/features/finance/presentation/providers/finance_voucher_providers.dart';
import 'package:sakal/features/finance/presentation/screens/journal_voucher_entry_screen.dart';

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
      (w) => w is RichText && w.text.toPlainText().toUpperCase().contains(label.toUpperCase()),
    );

void main() {
  late MockFinanceVoucherRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
  });

  setUp(() {
    mockRepo = MockFinanceVoucherRepository();
  });

  // JournalVoucherEntryScreen's own _init() unconditionally Future.waits on
  // accountsProvider/baseCurrencyProvider/localCurrencyProvider and watches
  // currenciesProvider directly for the Currency dropdown — all have to be
  // overridden regardless of new-vs-edit mode, or the real provider chain
  // runs and hits DioClient/a real datasource.
  //
  // Two plain ("General" nature) accounts — deliberately NOT Customer/
  // Supplier, to sidestep the bill-auto-tagging logic (out of scope per the
  // task brief) and NOT Cash/Bank (JournalVoucherEntryScreen's own picker
  // excludes those from _pickableAccounts).
  List<Override> overrides() => [
        financeVoucherRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
        accountsProvider.overrideWith((ref) async => [
              {
                'id': 'acc-101',
                'account_code': 'EXP-101',
                'account_name': 'Office Rent',
                'account_nature': 'General',
                'parent': {'account_name': 'Expenses'},
                'rim_currencies': {'currency_id': 'USD'},
              },
              {
                'id': 'acc-201',
                'account_code': 'INC-201',
                'account_name': 'Rent Received',
                'account_nature': 'General',
                'parent': {'account_name': 'Income'},
                'rim_currencies': {'currency_id': 'USD'},
              },
            ]),
        currenciesProvider.overrideWith((ref) async => [
              {'id': 'ccy-usd', 'currency_id': 'USD', 'currency_name': 'US Dollar', 'rate_decimal_places': 2},
            ]),
        baseCurrencyProvider.overrideWith((ref) async => 'USD'),
        localCurrencyProvider.overrideWith((ref) async => 'FC'),
      ];

  group('New (blank) journal voucher', () {
    testWidgets('renders the blank form with all key fields, one auto-added blank line, and no post-save actions',
        (tester) async {
      await pumpApp(tester, const JournalVoucherEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      expect(find.text('New Journal Voucher'), findsOneWidget);
      expect(find.text('Draft'), findsOneWidget);
      expect(_findFieldLabel('VOUCHER NO'), findsOneWidget);
      expect(_findFieldLabel('VOUCHER DATE'), findsOneWidget);
      expect(_findFieldLabel('REFERENCE NO'), findsOneWidget);
      expect(_findFieldLabel('REFERENCE DATE'), findsOneWidget);
      // 'Currency' appears twice — the header dropdown label AND the
      // auto-added blank line's own readonly Currency field.
      expect(_findFieldLabel('CURRENCY'), findsNWidgets(2));
      // 'Remarks' appears twice — the header field AND the line's own
      // Remarks field.
      expect(_findFieldLabel('REMARKS'), findsNWidgets(2));

      // _addLine() runs synchronously in initState() — a brand-new JV
      // always starts with exactly one blank account line, there's no
      // reachable "no lines" empty state on this screen.
      expect(find.text('Account Lines'), findsOneWidget);
      expect(_findFieldLabel('ACCOUNT'), findsOneWidget);
      // 'Amount' (editable) + the three readonly 'Base Amount'/'Local
      // Amount'/'Party Amount' fields all contain the substring "AMOUNT".
      expect(_findFieldLabel('AMOUNT'), findsNWidgets(4));
      expect(_findFieldLabel('DR / CR'), findsOneWidget);
      expect(find.text('Dr 0.00  /  Cr 0.00'), findsOneWidget);

      expect(find.text('Save Draft'), findsOneWidget);
      // A brand-new, never-saved voucher has no voucher number yet, so no
      // print button, no copy button, no approve, no reverse.
      expect(find.byIcon(Icons.print_outlined), findsNothing);
      expect(find.text('Copy'), findsNothing);
      expect(find.text('Approve'), findsNothing);
      expect(find.text('Reverse'), findsNothing);
    });

    testWidgets('blocks save and shows a validation message when no currency is selected', (tester) async {
      await pumpApp(tester, const JournalVoucherEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      // _saveDraft() checks currency first, before line count/balance.
      expect(find.text('Select a currency.'), findsOneWidget);
      verifyNever(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            userId: any(named: 'userId'),
          ));
    });
  });

  group('Editing an existing DRAFT (resume flow, two-line balanced entry)', () {
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
            transNo: 'JV-001',
            transDate: '2026-07-01',
            voucherTypeCode: 'JV',
            paymentModeCode: '',
            isOnAccount: true,
            referenceNo: 'REF-100',
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
            FinanceVoucherLine(
              serialNo: 1,
              accountId: 'acc-101',
              transNature: 'DR',
              transAmount: 500,
              transCurrency: 'USD',
              baseAmount: 500,
              baseRate: 1,
              localAmount: 750,
              localRate: 1.5,
              partyAmount: 500,
              partyCurrency: 'USD',
              partyRate: 1,
              invBillNo: '',
              invBillDate: '',
              lineRemarks: 'Rent expense line',
            ),
            FinanceVoucherLine(
              serialNo: 2,
              accountId: 'acc-201',
              transNature: 'CR',
              transAmount: 500,
              transCurrency: 'USD',
              baseAmount: 500,
              baseRate: 1,
              localAmount: 750,
              localRate: 1.5,
              partyAmount: 500,
              partyCurrency: 'USD',
              partyRate: 1,
              invBillNo: '',
              invBillDate: '',
              lineRemarks: 'Rent income line',
            ),
          ]);
    }

    testWidgets('loads and displays every field from the saved header and both lines', (tester) async {
      stubExistingDraft();

      await pumpApp(
        tester,
        const JournalVoucherEntryScreen(editTransNo: 'JV-001', editTransDate: '2026-07-01'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      expect(find.text('JV-001'), findsOneWidget);
      expect(find.text('Draft'), findsOneWidget);

      // Account lines — resumed straight from getLines(), matched against
      // accountsProvider by account_id, no autocomplete interaction needed.
      expect(find.text('[EXP-101] Office Rent'), findsOneWidget);
      expect(find.text('[INC-201] Rent Received'), findsOneWidget);
      expect(find.text('Expenses'), findsOneWidget); // Parent Group, line 1
      expect(find.text('Income'), findsOneWidget); // Parent Group, line 2
      expect(find.text('500.0'), findsNWidgets(2)); // amountCtrl.text via _fmtNum
      expect(find.text('DR'), findsOneWidget);
      expect(find.text('CR'), findsOneWidget);
      expect(find.text('Rent expense line'), findsOneWidget);
      expect(find.text('Rent income line'), findsOneWidget);
      expect(find.text('Dr 500.00  /  Cr 500.00'), findsOneWidget);

      expect(find.text('Original remarks'), findsOneWidget);

      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.text('Approve'), findsNothing); // canApprove defaults false from the harness's empty menuProvider
      expect(find.byIcon(Icons.print_outlined), findsOneWidget); // a saved voucher is printable
      expect(find.text('Copy'), findsOneWidget); // a saved voucher can be copied
      expect(find.text('Reverse'), findsNothing); // only shown once posted
    });

    testWidgets('editing remarks and saving calls the repository with the updated two-line payload', (tester) async {
      stubExistingDraft();
      when(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'JV-001');
      when(() => mockRepo.cacheVoucherLocally(
            effectiveTransNo: any(named: 'effectiveTransNo'),
            header: any(named: 'header'),
            lines: any(named: 'lines'),
          )).thenAnswer((_) async {});

      await pumpApp(
        tester,
        const JournalVoucherEntryScreen(editTransNo: 'JV-001', editTransDate: '2026-07-01'),
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

      expect(header['trans_no'], 'JV-001');
      expect(header['location_id'], 'loc-001');
      expect(header['voucher_type_code'], 'JV');
      expect(header['is_on_account'], true);
      expect(header['reference_no'], 'REF-100');
      expect(header['reference_date'], '2026-07-01');
      expect(header['remarks'], 'Updated remarks');

      expect(lines, hasLength(2));
      final drLine = lines[0];
      expect(drLine['serial_no'], 1);
      expect(drLine['account_id'], 'acc-101');
      expect(drLine['trans_nature'], 'DR');
      expect(drLine['trans_amount'], 500.0);
      expect(drLine['trans_currency'], 'USD');
      expect(drLine['base_amount'], 500.0); // trans_amount * baseRate (1.0, from line 1's own baseRate)
      expect(drLine['base_rate'], 1.0);
      expect(drLine['local_amount'], 750.0); // trans_amount * localRate (1.5, from line 1's own localRate)
      expect(drLine['local_rate'], 1.5);
      expect(drLine['party_amount'], 500.0); // accountCurrency == transCurrency ⇒ partyRate 1
      expect(drLine['party_currency'], 'USD');
      expect(drLine['line_remarks'], 'Rent expense line');

      final crLine = lines[1];
      expect(crLine['serial_no'], 2);
      expect(crLine['account_id'], 'acc-201');
      expect(crLine['trans_nature'], 'CR');
      expect(crLine['trans_amount'], 500.0);
      expect(crLine['base_amount'], 500.0);
      expect(crLine['local_amount'], 750.0);
      expect(crLine['party_amount'], 500.0);
      expect(crLine['line_remarks'], 'Rent income line');

      expect(find.text('Journal Voucher JV-001 saved.'), findsOneWidget);
    });
  });

  // Every prior JV test (Phase 5 + this file's own resume-flow tests)
  // deliberately excluded driving FinanceAccountPicker (built on
  // SakalAutocomplete) through real user interaction — this group types
  // into the auto-added first line's own Account field, picks a real
  // option from the rendered overlay, and confirms the selection lands.
  // Unlike GRN's own `_searchField<T>` (a plain Text row per option),
  // FinanceAccountPicker's optionBuilder renders Code/Name/Parent-Group as
  // three SEPARATE Text widgets (see finance_account_picker.dart's own
  // optionRow) — there is no single combined "[code] name" string to
  // find.text() against inside the overlay, only after a real selection
  // sets the field's own text via displayStringForOption. So the overlay
  // assertion below matches the account NAME column alone, and the
  // post-selection assertion matches the field's own combined text.
  group('Account picker interaction (real search + select) on a line', () {
    // Same exact-match helper as GRN's own pilot (see that file's own
    // comment) — a bare "Account" substring query would otherwise be
    // ambiguous with a future field on this screen, but exact-match keeps
    // this consistent with every other file in this rollout.
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

    testWidgets(
        "typing into the first line's Account field shows the matching option, and selecting it fills the field, Parent Group, and Currency",
        (tester) async {
      await pumpApp(tester, const JournalVoucherEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      // _addLine() runs synchronously in initState() — there's always
      // exactly one blank line to search within on a brand-new JV.
      final accountField = fieldInCard('Account', () => find.byType(TextFormField));
      await tester.enterText(accountField, 'Office');
      // FinanceAccountPicker's own _search() filters the already-loaded
      // accountsProvider list synchronously — pumpAndSettle just lets
      // RawAutocomplete's OverlayEntry render the filtered options.
      await tester.pumpAndSettle();

      // The overlay's optionRow renders code/name/parent as three separate
      // Text widgets — the account NAME is the unique, findable one (only
      // 'Office Rent' contains 'office'; 'Rent Received' does not).
      expect(find.text('Office Rent'), findsOneWidget);

      await tester.tap(find.text('Office Rent'));
      await tester.pumpAndSettle();

      // _onAccountSelected sets row.accountId/accountDisplay/parentName/
      // accountCurrency — the field's own displayed text (combined "[code]
      // name" via FinanceAccountPicker.displayString) is set internally by
      // RawAutocomplete itself as part of processing the selection, before
      // widget.onSelected (i.e. _onAccountSelected) even runs.
      expect(find.text('[EXP-101] Office Rent'), findsOneWidget);
      // Parent Group and Currency are plain readonly SakalFieldCards driven
      // by row.parentName/row.accountCurrency — they rebuild on every
      // setState with no remount/key gotcha, unlike the FormField-family
      // Account picker itself. accountCurrency ('USD') == _baseCcy so
      // _refreshLinePartyRate short-circuits with no exchange-rate fetch
      // needed — no extra repository stub required for this test.
      expect(find.text('Expenses'), findsOneWidget);
      expect(find.text('USD'), findsOneWidget);
    });
  });
}
