import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/layout/screen_header.dart';
import 'package:sakal/core/providers/master_cache_providers.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/core/widgets/sakal_field_card.dart';
import 'package:sakal/features/finance/domain/repositories/expense_voucher_repository.dart';
import 'package:sakal/features/finance/presentation/providers/expense_voucher_providers.dart';
import 'package:sakal/features/finance/presentation/screens/expense_voucher_entry_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockExpenseVoucherRepository extends Mock implements ExpenseVoucherRepository {}

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
  late MockExpenseVoucherRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
  });

  setUp(() {
    mockRepo = MockExpenseVoucherRepository();
  });

  // ExpenseVoucherEntryScreen uses ScreenPermissionMixin — pump_app.dart's
  // default empty menuProvider already yields canAdd/canEdit=true,
  // canApprove=false, a reasonable default for these tests, so no
  // menuProvider override is needed here (unlike FinanceVoucherEntryScreen,
  // which reads menuProvider directly via its own module-level helper).
  //
  // _init() always fetches base/local currency + accounts + currencies +
  // tax groups, regardless of new-vs-edit mode.
  List<Override> overrides() => [
        expenseVoucherRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
        // SIMPLE (the default) keeps the Location field hidden — matches
        // every existing assertion in this file, which predates the
        // Location-picker feature and never expects that field to appear.
        interLocationModelProvider.overrideWith((ref) async => 'SIMPLE'),
        accountsProvider.overrideWith((ref) async => [
              {'id': 'sup-001', 'account_code': 'SUP-001', 'account_name': 'Test Supplier', 'account_nature': 'Supplier', 'posting_allowed': true},
              {'id': 'exp-001', 'account_code': 'EXP-01', 'account_name': 'Electricity Expense', 'account_nature': 'Expense', 'posting_allowed': true},
            ]),
        currenciesProvider.overrideWith((ref) async => [
              {'id': 'ccy-usd', 'currency_id': 'USD', 'currency_name': 'US Dollar', 'rate_decimal_places': 2},
            ]),
        // Local == base on purpose in this fixture — keeps the conditional
        // "1 X = ? local" rate field out of the rendered tree entirely, since
        // driving it isn't part of this wave's scope.
        baseCurrencyProvider.overrideWith((ref) async => 'USD'),
        localCurrencyProvider.overrideWith((ref) async => 'USD'),
        taxGroupsProvider.overrideWith((ref) async => []),
      ];

  group('New (blank) expense voucher', () {
    testWidgets('renders the blank form with the mandatory Supplier line and no print/copy/approve buttons', (tester) async {
      await pumpApp(tester, const ExpenseVoucherEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      final header = _readHeader(tester, find.byType(ExpenseVoucherEntryScreen));
      expect(header?.title, 'New Expense Voucher');
      expect(header?.badgeText, 'Draft');

      expect(_findFieldLabel('VOUCHER NO'), findsOneWidget);
      expect(_findFieldLabel('VOUCHER DATE'), findsOneWidget);
      expect(_findFieldLabel('SUPPLIER'), findsOneWidget);
      expect(_findFieldLabel('CURRENCY'), findsOneWidget);
      expect(_findFieldLabel('BILL NO'), findsOneWidget);
      expect(_findFieldLabel('BILL DATE'), findsOneWidget);
      // Header Remarks + the one auto-added line's own Remarks field.
      expect(_findFieldLabel('REMARKS'), findsNWidgets(2));

      // _addLine() in initState() auto-adds one blank expense line even for
      // a brand-new voucher — the Supplier line being fixed/mandatory means
      // there's no genuine "zero lines" empty state on this screen.
      expect(find.text('Expense Lines'), findsOneWidget);
      expect(_findFieldLabel('EXPENSE ACCOUNT'), findsOneWidget);
      expect(_findFieldLabel('AMOUNT'), findsOneWidget);
      expect(_findFieldLabel('TAX GROUP (OPTIONAL)'), findsOneWidget);
      expect(find.text('None'), findsOneWidget); // Tax Group dropdown, nothing selected
      expect(find.byIcon(Icons.add_circle_outline), findsOneWidget); // add-line button
      expect(find.byIcon(Icons.close), findsNothing); // remove-line only shown when >1 line

      expect(find.textContaining('Net Payable: 0.00'), findsOneWidget);

      expect(find.text('Save Draft'), findsOneWidget);
      // A brand-new, never-saved voucher has no trans number yet, so no
      // print button, no copy button, and no approve/reverse button.
      expect(header?.actions.length, 1); // Save Draft now shows in the desktop TopBar
      expect(find.text('Copy'), findsNothing);
      expect(find.text('Approve'), findsNothing);
      expect(find.byIcon(Icons.undo), findsNothing);
    });

    testWidgets('blocks save and shows a validation message when no supplier is selected', (tester) async {
      await pumpApp(tester, const ExpenseVoucherEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      // _saveDraft() checks the supplier first, before currency/bill/lines.
      expect(find.text('Select a supplier.'), findsOneWidget);
      verifyNever(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            userId: any(named: 'userId'),
          ));
    });
  });

  group('Editing an existing DRAFT (resume flow)', () {
    void stubExistingDraft() {
      when(() => mockRepo.getHeader(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            transNo: any(named: 'transNo'),
          )).thenAnswer((_) async => {
            'trans_no': 'EXV-001',
            'trans_date': '2026-07-01',
            'status': 'DRAFT',
            'location_id': 'loc-001',
            'posted_voucher_no': null,
            'posted_voucher_date': null,
            'supplier_id': 'sup-001',
            'supplier': {'account_code': 'SUP-001', 'account_name': 'Test Supplier'},
            'currency_id': 'ccy-usd',
            'currency': {'currency_id': 'USD'},
            'rate_to_base': 1,
            'rate_to_local': 1,
            'bill_no': 'BILL-100',
            'bill_date': '2026-06-28',
            'remarks': 'Original remarks',
            'created_by_user': {'full_name': 'Test User'},
            'approved_by_user': null,
          });
      when(() => mockRepo.getLines(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            transNo: any(named: 'transNo'),
            transDate: any(named: 'transDate'),
          )).thenAnswer((_) async => [
            {
              'account_id': 'exp-001',
              'account': {'account_code': 'EXP-01', 'account_name': 'Electricity Expense'},
              'amount': 500,
              'tax_group_id': null,
              'tax_group': null,
              'line_remarks': 'Monthly bill',
            },
          ]);
    }

    testWidgets('loads and displays every field from the saved header and line', (tester) async {
      stubExistingDraft();

      await pumpApp(
        tester,
        const ExpenseVoucherEntryScreen(editTransNo: 'EXV-001'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      final header = _readHeader(tester, find.byType(ExpenseVoucherEntryScreen));
      expect(header?.title, 'EXV-001');
      expect(header?.badgeText, 'Draft');
      // The read-only Voucher No field card's own value — the title itself
      // no longer renders as body text (moved to the TopBar via the header
      // provider, asserted above).
      expect(find.text('EXV-001'), findsOneWidget);
      expect(find.text('[SUP-001] Test Supplier'), findsOneWidget); // Supplier autocomplete field text
      expect(find.text('USD'), findsOneWidget); // Currency dropdown, single fixture entry
      expect(find.text('01 Jul 2026'), findsOneWidget); // Voucher Date
      expect(find.text('BILL-100'), findsOneWidget);
      expect(find.text('28 Jun 2026'), findsOneWidget); // Bill Date
      expect(find.text('Original remarks'), findsOneWidget); // header Remarks

      expect(find.text('[EXP-01] Electricity Expense'), findsOneWidget); // line account autocomplete text
      expect(find.text('500'), findsOneWidget); // amountCtrl set via _fmtNum(500)
      expect(find.text('None'), findsOneWidget); // no tax group on this line
      expect(find.text('Monthly bill'), findsOneWidget); // line Remarks

      expect(find.textContaining('Net Payable: 500.00 USD'), findsOneWidget);

      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget); // saved + not locked → copy allowed
      expect(find.text('Approve'), findsNothing); // canApprove defaults false from the harness's empty menuProvider
      expect(header?.actions.length, 3); // Copy + Save Draft + Print all show in the desktop TopBar
      expect(find.byIcon(Icons.undo), findsNothing); // not posted → no reverse button
    });

    testWidgets('editing remarks and saving calls the repository with the updated payload', (tester) async {
      stubExistingDraft();
      when(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'EXV-001');
      when(() => mockRepo.cacheVoucherLocally(
            effectiveTransNo: any(named: 'effectiveTransNo'),
            header: any(named: 'header'),
            lines: any(named: 'lines'),
          )).thenAnswer((_) async {});

      await pumpApp(
        tester,
        const ExpenseVoucherEntryScreen(editTransNo: 'EXV-001'),
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

      expect(header['trans_no'], 'EXV-001');
      expect(header['trans_date'], '2026-07-01');
      expect(header['supplier_id'], 'sup-001');
      expect(header['currency_id'], 'ccy-usd');
      expect(header['rate_to_base'], 1.0);
      expect(header['rate_to_local'], 1.0);
      expect(header['bill_no'], 'BILL-100');
      expect(header['bill_date'], '2026-06-28');
      expect(header['remarks'], 'Updated remarks');

      expect(lines, hasLength(1));
      final line = lines.first;
      expect(line['account_id'], 'exp-001');
      expect(line['amount'], 500.0);
      expect(line['tax_group_id'], null);
      expect(line['line_remarks'], 'Monthly bill');

      expect(find.text('Expense Voucher EXV-001 saved.'), findsOneWidget);
    });
  });

  // Every prior Expense Voucher test deliberately excluded driving
  // FinanceAccountPicker through real user interaction — this group
  // drives both of this screen's own pickers: the header Supplier field,
  // and the auto-added first line's own Expense Account field. Same
  // FinanceAccountPicker three-separate-Text-widgets overlay shape as
  // Journal/Contra Voucher (see finance_account_picker.dart's optionRow).
  group('Supplier + Expense Account picker interaction (real search + select)', () {
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

    testWidgets('typing into the Supplier field shows the matching option, and tapping it selects the supplier', (tester) async {
      await pumpApp(tester, const ExpenseVoucherEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      final supplierField = fieldInCard('Supplier', () => find.byType(TextFormField));
      await tester.enterText(supplierField, 'Test');
      await tester.pumpAndSettle();

      // FinanceAccountPicker's optionRow renders Code/Name/Parent as
      // separate Text widgets — the account NAME is the unique findable
      // one (this fixture's only Supplier-natured account).
      expect(find.text('Test Supplier'), findsOneWidget);

      await tester.tap(find.text('Test Supplier'));
      // FinanceAccountPicker here carries `key: ValueKey(_supplierDisplay)`
      // (see _buildHeaderSection) — selecting changes _supplierDisplay,
      // forcing a remount; pumpAndSettle lets that finish.
      await tester.pumpAndSettle();

      // _onSupplierSelected sets _supplierId/_supplierDisplay — this
      // fixture's account has no 'rim_currencies' key at all, so the
      // auto-currency-fetch branch inside _onSupplierSelected is skipped
      // entirely (no repository stub needed), leaving the field's own
      // displayed text the simplest observable proof.
      expect(find.text('[SUP-001] Test Supplier'), findsOneWidget);
    });

    testWidgets("typing into the first line's Expense Account field shows the matching option, and selecting it fills the line",
        (tester) async {
      await pumpApp(tester, const ExpenseVoucherEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      // _addLine() runs synchronously in initState() — a brand-new
      // Expense Voucher always starts with exactly one blank line.
      final expenseAccountField = fieldInCard('Expense Account', () => find.byType(TextFormField));
      await tester.enterText(expenseAccountField, 'Electric');
      await tester.pumpAndSettle();

      expect(find.text('Electricity Expense'), findsOneWidget);

      await tester.tap(find.text('Electricity Expense'));
      await tester.pumpAndSettle();

      // _onLineAccountSelected sets row.accountId/accountDisplay; this
      // fixture's account has no default_tax_group_id, so the
      // auto-suggest Tax Group branch is skipped, and with no tax group
      // on any line, _refreshTaxPreview() short-circuits before making
      // any repository call (groupIds.isEmpty) — no extra stub needed.
      expect(find.text('[EXP-01] Electricity Expense'), findsOneWidget);
    });
  });
}
