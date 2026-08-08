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
      (w) => w is RichText && w.maxLines == 1 && w.text.toPlainText().toUpperCase().contains(label.toUpperCase()),
    );

/// Locates a field's own input widget by finding the SakalFieldCard whose
/// label RichText exactly matches (with or without the required " *"
/// suffix), then descending into it. Hoisted to file scope so both the
/// desktop and mobile Account-picker interaction groups can share it.
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

      final header = _readHeader(tester, find.byType(JournalVoucherEntryScreen));
      expect(header?.title, 'New Journal Voucher');
      expect(header?.badgeText, 'Draft');
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
      expect(_findFieldLabel('ACCOUNT *'), findsOneWidget);
      // 'Amount' (editable) + the three readonly 'Base Amount'/'Local
      // Amount'/'Party Amount' fields all contain the substring "AMOUNT".
      expect(_findFieldLabel('AMOUNT'), findsNWidgets(4));
      expect(_findFieldLabel('DR / CR'), findsOneWidget);
      expect(find.text('Dr 0.00  /  Cr 0.00'), findsOneWidget);

      expect(find.text('Save Draft'), findsOneWidget);
      // A brand-new, never-saved voucher has no voucher number yet, so no
      // print button, no copy button, no approve, no reverse.
      expect(header?.actions, isEmpty);
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

      final header = _readHeader(tester, find.byType(JournalVoucherEntryScreen));
      expect(header?.title, 'JV-001');
      expect(header?.badgeText, 'Draft');
      // The read-only Voucher No field card's own value — the title itself
      // no longer renders as body text (moved to the TopBar via the header
      // provider, asserted above).
      expect(find.text('JV-001'), findsOneWidget);

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
      expect(header?.actions.length, 1); // a saved voucher is printable
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

  // SakalAutocomplete forks its whole rendering path on Responsive.isMobile
  // (a plain MediaQuery width < 600 check) — a showModalBottomSheet picker
  // instead of RawAutocomplete's inline overlay, so the keyboard can never
  // cover it. Before this file's own group below, NO test anywhere in the
  // suite rendered a SakalAutocomplete-using screen below 600px width, so
  // this whole code path (plus the focus-chaining fix that makes
  // `.requestFocus()` open the sheet on mobile — see sakal_autocomplete.dart's
  // own _onFocusChange) had zero coverage.
  group('Mobile picker (bottom sheet)', () {
    // JournalVoucherEntryScreen's own initState() calls _addLine()
    // synchronously, and _addLine() always requests focus on the new
    // line's own accountFocusNode — on mobile that's exactly the
    // focus-chaining fix under test, so the seed line's sheet auto-opens
    // on the very first pumpAndSettle() of every test in this group.
    Future<void> pumpMobile(WidgetTester tester) async {
      tester.view.physicalSize = const Size(375, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpApp(tester, const JournalVoucherEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();
    }

    testWidgets(
        'the seed line\'s Account field auto-opens the bottom sheet via focus-chaining on load; '
        'closing it and tapping the field manually reopens it; searching filters, and selecting closes '
        'the sheet with the result showing in the field',
        (tester) async {
      await pumpMobile(tester);

      // Focus-chaining fix: _addLine()'s own row.accountFocusNode.requestFocus()
      // (unchanged, pre-existing code) now opens the picker sheet on mobile
      // instead of silently doing nothing.
      expect(find.byType(BottomSheet), findsOneWidget);

      // Only one line exists yet, so the "Remove line" button (which also
      // uses Icons.close, gated on _lines.length > 1) isn't in the tree —
      // this close icon is unambiguously the sheet's own.
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);

      // Manually tapping the field (an InkWell wrapping an IgnorePointer'd
      // TextFormField on mobile — warnIfMissed:false since the tap
      // legitimately lands on the ancestor InkWell, not the TextFormField
      // itself, which IgnorePointer deliberately excludes from hit-testing)
      // reopens the same sheet.
      final accountField = fieldInCard('Account', () => find.byType(TextFormField));
      await tester.tap(accountField, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);

      // The sheet owns its own separate search TextField — not the outer
      // field, which stays IgnorePointer'd throughout. A bare
      // find.byType(TextField) also matches every other on-screen
      // TextFormField's own internal TextField (TextFormField is built on
      // top of TextField), so this must be scoped to inside the sheet.
      await tester.enterText(find.descendant(of: find.byType(BottomSheet), matching: find.byType(TextField)), 'Office');
      await tester.pumpAndSettle();
      expect(find.text('Office Rent'), findsOneWidget);
      expect(find.text('Rent Received'), findsNothing);

      await tester.tap(find.text('Office Rent'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('[EXP-101] Office Rent'), findsOneWidget);
    });

    testWidgets(
        "FinanceAccountPicker's code/name/parent columns render inside the mobile sheet without a layout overflow",
        (tester) async {
      await pumpMobile(tester);

      // Seed line's sheet is already open (focus-chaining) — optionBuilder
      // (FinanceAccountPicker's 3-column optionRow: fixed-width code +
      // Expanded name + Expanded parent) renders identically on mobile,
      // just wrapped in the sheet's own Padding instead of the desktop
      // overlay's Container. At 375px width this is the narrowest this
      // layout has ever actually been exercised.
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(tester.takeException(), isNull);

      expect(find.text('Office Rent'), findsOneWidget);
      expect(find.text('Expenses'), findsOneWidget); // parent group, line 1
      expect(find.text('Rent Received'), findsOneWidget);
      expect(find.text('Income'), findsOneWidget); // parent group, line 2
    });

    testWidgets(
        'tapping "Add line" auto-opens the new line\'s picker via focus-chaining with no tap on its field, '
        'and selecting an option does not reopen the sheet afterwards',
        (tester) async {
      await pumpMobile(tester);

      // Dismiss the seed line's own auto-opened sheet first — at this
      // point there's still only one line, so Icons.close is unambiguous.
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);

      // The real "Add line" button _addLine() uses in production — not a
      // raw FocusNode reach-around — so this exercises the exact same
      // chain a real user's tap does: _addLine() adds a second row, then
      // (in its own existing addPostFrameCallback) requests focus on that
      // row's accountFocusNode, which the fix under test turns into
      // opening the sheet, with no tap on the new field itself.
      await tester.ensureVisible(find.byTooltip('Add line'));
      await tester.tap(find.byTooltip('Add line'));
      // The focus-chaining fix schedules its own addPostFrameCallback
      // chain (unfocus, then open the sheet) on top of _addLine()'s own —
      // a couple of explicit pumps first gives every scheduled frame a
      // chance to run before pumpAndSettle does its final settle pass.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);

      await tester.tap(find.text('Office Rent'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);

      // Regression guard for the reopen-loop risk: _focusNode.unfocus() is
      // called BEFORE the sheet opens specifically so nothing tries to
      // restore focus to it once the sheet's route pops — confirm the
      // sheet genuinely stays closed after further settling, not just
      // closed at the instant of the assertion above.
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(BottomSheet), findsNothing);
    });
  });
}
