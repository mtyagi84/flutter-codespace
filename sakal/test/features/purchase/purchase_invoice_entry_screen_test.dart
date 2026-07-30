import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/providers/master_cache_providers.dart';
import 'package:sakal/features/purchase/data/models/purchase_invoice_model.dart';
import 'package:sakal/features/purchase/domain/repositories/purchase_invoice_repository.dart';
import 'package:sakal/features/purchase/presentation/providers/purchase_invoice_providers.dart';
import 'package:sakal/features/purchase/presentation/screens/purchase_invoice_entry_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockPurchaseInvoiceRepository extends Mock implements PurchaseInvoiceRepository {}

// mocktail needs a registered fallback value for any()/captureAny() used on
// a custom (non-generated) argument type in a when()/verify() call.
class _FakeStringDynamicMap extends Fake implements Map<String, dynamic> {}
class _FakeStringDynamicMapList extends Fake implements List<Map<String, dynamic>> {}
// grnRefs is specifically List<Map<String, String>>, a distinct type from
// the List<Map<String, dynamic>> used everywhere else in this app's save
// payloads — needs its own fallback.
class _FakeStringStringMapList extends Fake implements List<Map<String, String>> {}

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
  late MockPurchaseInvoiceRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
    registerFallbackValue(_FakeStringStringMapList());
  });

  setUp(() {
    mockRepo = MockPurchaseInvoiceRepository();
    // Every test reaches _init(), which always calls
    // getSuppliersWithPendingGrns() first regardless of new-vs-edit mode.
    when(() => mockRepo.getSuppliersWithPendingGrns(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => []);
  });

  List<Override> overrides() => [
        purchaseInvoiceRepositoryProvider.overrideWithValue(mockRepo),
        // currenciesProvider hits DioClient directly when unmocked — override
        // its Future straight to a fixed list so the header card's currency
        // row resolves without a real network/platform-channel dependency.
        currenciesProvider.overrideWith((ref) async => [
              {'id': 'ccy-001', 'currency_id': 'USD', 'currency_name': 'US Dollar', 'rate_decimal_places': 2},
            ]),
      ];

  group('New (blank) invoice', () {
    testWidgets('renders the blank form with all key fields (consolidation-only screen, no product lines)', (tester) async {
      await pumpApp(tester, const PurchaseInvoiceEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      expect(find.text('New Purchase Bill'), findsOneWidget);
      expect(find.text('Unsaved draft'), findsOneWidget);

      // "SUPPLIER" alone matches 3 labels on this screen (Supplier, Supplier
      // Invoice No, Supplier Invoice Date) since _findFieldLabel is a
      // contains-match — assert the precise count rather than
      // findsOneWidget, which would be a false failure here.
      expect(_findFieldLabel('SUPPLIER'), findsNWidgets(3));
      expect(_findFieldLabel('BILL NO'), findsOneWidget);
      expect(_findFieldLabel('BILL DATE'), findsOneWidget);
      expect(_findFieldLabel('SUPPLIER INVOICE NO'), findsOneWidget);
      expect(_findFieldLabel('SUPPLIER INVOICE DATE'), findsOneWidget);
      expect(_findFieldLabel('CURRENCY (INHERITED FROM GRN)'), findsOneWidget);
      expect(_findFieldLabel('RATE → BASE'), findsOneWidget);
      expect(_findFieldLabel('RATE → LOCAL'), findsOneWidget);

      // GRN picker card — this screen consolidates from one or more GRNs,
      // there is no free-text "Add Line" affordance anywhere.
      expect(find.text('Pending GRNs'), findsOneWidget);
      expect(find.text('Select a supplier to see their approved, not-yet-billed GRNs.'), findsOneWidget);

      expect(_findFieldLabel('TAXABLE AMOUNT'), findsOneWidget);
      expect(_findFieldLabel('VAT / TAX AMOUNT'), findsOneWidget);
      expect(_findFieldLabel('INVOICE TOTAL'), findsOneWidget);
      expect(_findFieldLabel('REMARKS'), findsOneWidget);

      expect(find.text('Save Draft'), findsOneWidget);
      // A brand-new, never-saved bill has no invoice number yet, so no
      // print button and no approve button (approve requires !_isNew).
      expect(find.byIcon(Icons.print_outlined), findsNothing);
      expect(find.text('Approve'), findsNothing);
    });

    testWidgets('blocks save and shows a validation message when no supplier is selected', (tester) async {
      await pumpApp(tester, const PurchaseInvoiceEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      expect(find.text('Select a supplier.'), findsOneWidget);
      verifyNever(() => mockRepo.save(
            header: any(named: 'header'),
            grnRefs: any(named: 'grnRefs'),
            userId: any(named: 'userId'),
          ));
    });
  });

  group('Editing an existing DRAFT (resume flow — consolidated from GRN(s))', () {
    void stubExistingDraft() {
      when(() => mockRepo.getHeader(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            invoiceNo: any(named: 'invoiceNo'),
            invoiceDate: any(named: 'invoiceDate'),
          )).thenAnswer((_) async => const PurchaseInvoiceModel(
            id: 'inv-1',
            clientId: 'client-001',
            companyId: 'company-001',
            locationId: 'loc-001',
            invoiceNo: 'PINV-001',
            invoiceDate: '2026-07-05',
            supplierId: 'sup-001',
            supplierCode: 'SUP01',
            supplierName: 'Supplier One',
            supplierInvoiceNo: 'INV-123',
            supplierInvoiceDate: '2026-07-01',
            invoiceCurrencyId: 'ccy-001',
            invoiceCurrencyCode: 'USD',
            rateToBase: 1,
            rateToLocal: 1,
            taxableAmount: 1000,
            taxAmount: 160,
            invoiceTotal: 1160,
            remarks: 'Invoice remarks',
            status: 'DRAFT',
          ));
      when(() => mockRepo.getPendingGrnsForSupplier(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            supplierId: any(named: 'supplierId'),
            excludeInvoiceNo: any(named: 'excludeInvoiceNo'),
          )).thenAnswer((_) async => [
            {
              'grn_no': 'GRN-001',
              'grn_date': '2026-06-30',
              'grn_currency_id': 'ccy-001',
              'currency': {'currency_id': 'USD'},
              'rate_to_base': 1,
              'rate_to_local': 1,
              // Matches the resumed invoice's own invoice_no — this is what
              // makes _init() pre-check this GRN's checkbox on load.
              'billed_invoice_no': 'PINV-001',
            },
          ]);
    }

    testWidgets('loads and displays every field from the saved header and pre-selected GRN', (tester) async {
      stubExistingDraft();

      await pumpApp(
        tester,
        const PurchaseInvoiceEntryScreen(editInvoiceNo: 'PINV-001', editInvoiceDate: '2026-07-05'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      expect(find.text('Purchase Bill · PINV-001'), findsOneWidget);
      expect(find.text('Draft'), findsOneWidget);
      expect(find.textContaining('Supplier One'), findsWidgets); // '[SUP01] Supplier One'
      expect(find.text('INV-123'), findsOneWidget); // Supplier Invoice No
      expect(find.text('Invoice remarks'), findsOneWidget);
      expect(find.text('USD — US Dollar'), findsOneWidget); // Currency, resolved from currenciesProvider

      // GRN picker — pre-checked because billed_invoice_no already equals
      // this invoice's own invoice_no.
      expect(find.text('GRN-001'), findsOneWidget);

      // header.taxableAmount/taxAmount are doubles assigned via
      // `.toString()` (not toStringAsFixed) in _init() — 1000 -> "1000.0".
      expect(find.text('1000.0'), findsOneWidget);
      expect(find.text('160.0'), findsOneWidget);

      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.text('Approve'), findsNothing); // canApprove defaults false from the harness's empty menuProvider
      expect(find.byIcon(Icons.print_outlined), findsOneWidget); // a saved bill is printable
    });

    testWidgets('editing remarks and saving calls the repository with the updated payload', (tester) async {
      stubExistingDraft();
      when(() => mockRepo.save(
            header: any(named: 'header'),
            grnRefs: any(named: 'grnRefs'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'PINV-001');

      await pumpApp(
        tester,
        const PurchaseInvoiceEntryScreen(editInvoiceNo: 'PINV-001', editInvoiceDate: '2026-07-05'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.text('Invoice remarks'), 'Updated remarks');
      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      final captured = verify(() => mockRepo.save(
            header: captureAny(named: 'header'),
            grnRefs: captureAny(named: 'grnRefs'),
            userId: any(named: 'userId'),
          )).captured;
      final header = captured[0] as Map<String, dynamic>;
      final grnRefs = captured[1] as List<Map<String, String>>;

      expect(header['client_id'], 'client-001');
      expect(header['company_id'], 'company-001');
      expect(header['location_id'], 'loc-001');
      expect(header['invoice_no'], 'PINV-001');
      expect(header['invoice_date'], '2026-07-05');
      expect(header['supplier_id'], 'sup-001');
      expect(header['supplier_invoice_no'], 'INV-123');
      expect(header['supplier_invoice_date'], '2026-07-01');
      expect(header['invoice_currency_id'], 'ccy-001');
      expect(header['rate_to_base'], 1.0);
      expect(header['rate_to_local'], 1.0);
      expect(header['taxable_amount'], 1000.0);
      expect(header['tax_amount'], 160.0);
      expect(header['invoice_total'], 1160.0);
      expect(header['remarks'], 'Updated remarks');

      expect(grnRefs, hasLength(1));
      expect(grnRefs.first['grn_no'], 'GRN-001');
      expect(grnRefs.first['grn_date'], '2026-06-30');

      expect(find.text('Purchase Bill PINV-001 saved.'), findsOneWidget);
    });
  });
}
