import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/features/sales/domain/repositories/cash_receipt_repository.dart';
import 'package:sakal/features/sales/presentation/providers/cash_receipt_providers.dart';
import 'package:sakal/features/sales/presentation/screens/cash_receipt_entry_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockCashReceiptRepository extends Mock implements CashReceiptRepository {}

// mocktail needs a registered fallback value for any()/captureAny() used on
// a Map/List argument matcher in a when()/verify() call.
class _FakeStringDynamicMap extends Fake implements Map<String, dynamic> {}
class _FakeStringDynamicMapList extends Fake implements List<Map<String, dynamic>> {}

/// pumpAndSettle() right after a save/validate action is a trap: it keeps
/// pumping until every animation/timer settles, including a SnackBar's own
/// auto-dismiss timer (~4s) — by then the very text under test may already
/// be gone. A few short, bounded pumps let pending async work resolve
/// without running anywhere near that long.
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
  late MockCashReceiptRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
  });

  setUp(() {
    mockRepo = MockCashReceiptRepository();
  });

  List<Override> overrides() => [
        cashReceiptRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  // _init() always calls getCompanyCurrencies/getUsersForAutocomplete/
  // getQuickInvoiceSetup first, regardless of new-vs-edit mode. Also
  // provides the three getExchangeRate stubs every test needs: the header's
  // own Base->Local rate (used unconditionally for the "Total Receipt"
  // field), plus a pending bill's own party-currency (EUR, deliberately
  // different from both Base=USD and Local=FC so the three Balance columns
  // never collide on the same formatted amount) -> Base and -> Local rates.
  void stubBaseline() {
    when(() => mockRepo.getCompanyCurrencies(companyId: any(named: 'companyId')))
        .thenAnswer((_) async => {'base_currency': 'USD', 'local_currency': 'FC'});
    when(() => mockRepo.getUsersForAutocomplete(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => []);
    when(() => mockRepo.getQuickInvoiceSetup(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          userId: any(named: 'userId'),
        )).thenAnswer((_) async => {
              'location_id': 'loc-001',
              'location': {'location_name': 'Main Branch'},
              'local_cash_account': {'account_code': 'CASH-L', 'account_name': 'Local Cash'},
              'base_cash_account': {'account_code': 'CASH-B', 'account_name': 'Base Cash'},
            });
    when(() => mockRepo.getExchangeRate(
          companyId: any(named: 'companyId'),
          locationId: any(named: 'locationId'),
          fromCurrency: 'USD',
          toCurrency: 'FC',
          rateDate: any(named: 'rateDate'),
        )).thenAnswer((_) async => 2.0);
    when(() => mockRepo.getExchangeRate(
          companyId: any(named: 'companyId'),
          locationId: any(named: 'locationId'),
          fromCurrency: 'EUR',
          toCurrency: 'USD',
          rateDate: any(named: 'rateDate'),
        )).thenAnswer((_) async => 1.1);
    when(() => mockRepo.getExchangeRate(
          companyId: any(named: 'companyId'),
          locationId: any(named: 'locationId'),
          fromCurrency: 'EUR',
          toCurrency: 'FC',
          rateDate: any(named: 'rateDate'),
        )).thenAnswer((_) async => 2.5);
  }

  group('New (blank) Cash Receipt', () {
    testWidgets('renders the blank form with all key fields and no print button', (tester) async {
      stubBaseline();

      await pumpApp(tester, const CashReceiptEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      expect(find.text('New Cash Receipt'), findsOneWidget);
      expect(find.text('DRAFT'), findsOneWidget);

      expect(_findFieldLabel('LOCATION'), findsOneWidget);
      expect(_findFieldLabel('LOCAL CASH ACCOUNT'), findsOneWidget);
      expect(_findFieldLabel('BASE CASH ACCOUNT'), findsOneWidget);
      expect(_findFieldLabel('RECEIPT DATE'), findsOneWidget);
      expect(_findFieldLabel('CASH RECEIVED (LOCAL'), findsOneWidget);
      expect(_findFieldLabel('CASH RECEIVED (BASE'), findsOneWidget);
      expect(_findFieldLabel('TOTAL RECEIPT (LOCAL EQUIVALENT)'), findsOneWidget);
      expect(_findFieldLabel('REMARKS'), findsOneWidget);
      expect(_findFieldLabel('CUSTOMER'), findsOneWidget);

      // Prefilled, read-only Quick Invoice Setup values.
      expect(find.text('Main Branch'), findsOneWidget);
      expect(find.text('[CASH-L] Local Cash'), findsOneWidget);
      expect(find.text('[CASH-B] Base Cash'), findsOneWidget);

      // Total Receipt (Local Equivalent) with nothing typed yet.
      expect(find.text('0.00'), findsOneWidget);

      // No customer selected yet -> the whole Pending Invoices section is
      // not rendered at all (gated on `_customerId != null`).
      expect(find.text('Pending Invoices'), findsNothing);

      expect(find.text('Save & Collect'), findsOneWidget);
      // A brand-new, never-saved receipt has no receipt number yet, and
      // this screen only ever prints an APPROVED receipt.
      expect(find.byIcon(Icons.print_outlined), findsNothing);
    });

    testWidgets('blocks save and shows a validation message when no customer is selected', (tester) async {
      stubBaseline();

      await pumpApp(tester, const CashReceiptEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save & Collect'));
      await _pumpBriefly(tester);

      // _saveAndApprove() checks Quick Invoice Setup first (valid here),
      // then the customer — still unselected on a blank form.
      expect(find.text('Select a customer.'), findsOneWidget);
      verifyNever(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            userId: any(named: 'userId'),
          ));
    });
  });

  group('Editing an existing DRAFT (resume flow, single pending bill)', () {
    void stubExistingDraft() {
      when(() => mockRepo.getHeader(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            receiptNo: any(named: 'receiptNo'),
          )).thenAnswer((_) async => {
                'receipt_no': 'CR-001',
                'receipt_date': '2026-07-20',
                'status': 'DRAFT',
                'customer_id': 'cust-001',
                'customer': {'account_code': 'CUS01', 'account_name': 'Customer One'},
                'local_amount': 300,
                'base_amount': 100,
                'remarks': 'Original remarks',
                'created_by': 'user-001',
                'approved_by': null,
                'location_id': 'loc-001',
                'location': {'location_name': 'Main Branch'},
              });
      when(() => mockRepo.getPendingBills(
            companyId: any(named: 'companyId'),
            locationId: any(named: 'locationId'),
            accountId: any(named: 'accountId'),
          )).thenAnswer((_) async => [
                {
                  'inv_bill_no': 'SI-001',
                  'inv_bill_date': '2026-07-10',
                  'party_currency': 'EUR',
                  'balance_amount': 700,
                },
              ]);
      when(() => mockRepo.getLines(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            receiptNo: any(named: 'receiptNo'),
            receiptDate: any(named: 'receiptDate'),
          )).thenAnswer((_) async => [
                {
                  'inv_bill_no': 'SI-001',
                  'inv_bill_date': '2026-07-10',
                  'applied_amount_local': 500,
                },
              ]);
    }

    testWidgets('loads and displays every field from the saved header and pending bill', (tester) async {
      stubBaseline();
      stubExistingDraft();

      await pumpApp(
        tester,
        const CashReceiptEntryScreen(editReceiptNo: 'CR-001'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      expect(find.text('CR-001'), findsOneWidget); // title is the bare receipt number
      expect(find.text('DRAFT'), findsOneWidget);
      expect(find.text('Main Branch'), findsOneWidget);
      expect(find.text('[CASH-L] Local Cash'), findsOneWidget);
      expect(find.text('[CASH-B] Base Cash'), findsOneWidget);
      expect(find.text('20 Jul 2026'), findsOneWidget); // Receipt Date
      expect(find.text('[CUS01] Customer One'), findsOneWidget); // Customer autocomplete field
      expect(find.text('300.0'), findsOneWidget); // Cash Received (Local) — raw controller text
      expect(find.text('100.0'), findsOneWidget); // Cash Received (Base) — raw controller text
      expect(find.text('500.00'), findsOneWidget); // Total Receipt (Local Equivalent) — formatted
      expect(find.text('Original remarks'), findsOneWidget);

      // Pending bill card, restored from the saved line.
      expect(find.text('Pending Invoices'), findsOneWidget);
      expect(find.text('Applied: 500.00 / 500.00'), findsOneWidget);
      expect(find.text('SI-001\n2026-07-10'), findsOneWidget);
      expect(_findFieldLabel('BALANCE (EUR)'), findsOneWidget);
      expect(_findFieldLabel('BALANCE (USD)'), findsOneWidget);
      expect(_findFieldLabel('BALANCE (FC)'), findsOneWidget);
      expect(find.text('700.00'), findsOneWidget); // Balance (EUR) — raw party balance
      expect(find.text('770.00'), findsOneWidget); // Balance (USD) — 700 * 1.1
      expect(find.text('1,750.00'), findsOneWidget); // Balance (FC) — 700 * 2.5
      expect(_findFieldLabel('APPLY (FC)'), findsOneWidget);
      expect(find.text('500.0'), findsOneWidget); // Apply field, restored from the saved line

      expect(find.text('Save & Collect'), findsOneWidget);
      // Still DRAFT (queued offline, never yet approved) — this screen only
      // prints an APPROVED receipt, even once a receipt number exists.
      expect(find.byIcon(Icons.print_outlined), findsNothing);
    });

    testWidgets('editing remarks and saving calls save+approve with the updated payload', (tester) async {
      stubBaseline();
      stubExistingDraft();
      when(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'CR-001');
      when(() => mockRepo.approve(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            receiptNo: any(named: 'receiptNo'),
            receiptDate: any(named: 'receiptDate'),
            approvedBy: any(named: 'approvedBy'),
          )).thenAnswer((_) async {});
      when(() => mockRepo.getPostedVouchers(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            receiptNo: any(named: 'receiptNo'),
          )).thenAnswer((_) async => []);

      await pumpApp(
        tester,
        const CashReceiptEntryScreen(editReceiptNo: 'CR-001'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.text('Original remarks'), 'Updated remarks');
      await tester.tap(find.text('Save & Collect'));
      await _pumpBriefly(tester);

      final captured = verify(() => mockRepo.save(
            header: captureAny(named: 'header'),
            lines: captureAny(named: 'lines'),
            userId: any(named: 'userId'),
          )).captured;
      final header = captured[0] as Map<String, dynamic>;
      final lines = captured[1] as List<Map<String, dynamic>>;

      expect(header['client_id'], 'client-001');
      expect(header['company_id'], 'company-001');
      expect(header['location_id'], 'loc-001');
      expect(header['receipt_no'], 'CR-001');
      expect(header['receipt_date'], '2026-07-20');
      expect(header['customer_id'], 'cust-001');
      expect(header['local_amount'], 300.0);
      expect(header['base_amount'], 100.0);
      expect(header['remarks'], 'Updated remarks');

      expect(lines, hasLength(1));
      final line = lines.first;
      expect(line['inv_bill_no'], 'SI-001');
      expect(line['inv_bill_date'], '2026-07-10');
      expect(line['bill_currency'], 'EUR');
      expect(line['applied_amount_local'], 500.0);

      verify(() => mockRepo.approve(
            clientId: 'client-001',
            companyId: 'company-001',
            receiptNo: 'CR-001',
            receiptDate: '2026-07-20',
            approvedBy: 'user-001',
          )).called(1);

      expect(find.text('Cash Receipt CR-001 collected and posted.'), findsOneWidget);
    });
  });
}
