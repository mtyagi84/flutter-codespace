import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/providers/master_cache_providers.dart';
import 'package:sakal/core/sync/sync_engine.dart';
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
      (w) => w is RichText && w.text.toPlainText().toUpperCase().contains(label.toUpperCase()),
    );

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
        accountsProvider.overrideWith((ref) async => [
              {'id': 'sup-001', 'account_code': 'SUP-001', 'account_name': 'Test Supplier', 'account_nature': 'Supplier'},
              {'id': 'exp-001', 'account_code': 'EXP-01', 'account_name': 'Electricity Expense', 'account_nature': 'Expense'},
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

      expect(find.text('New Expense Voucher'), findsOneWidget);
      expect(find.text('Draft'), findsOneWidget);

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
      expect(find.byIcon(Icons.print_outlined), findsNothing);
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

      // Title Text + read-only Voucher No field both render the same string.
      expect(find.text('EXV-001'), findsNWidgets(2));
      expect(find.text('Draft'), findsOneWidget);
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
      expect(find.byIcon(Icons.print_outlined), findsOneWidget); // a saved voucher is printable
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
}
