import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/providers/master_cache_providers.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/core/widgets/sakal_field_card.dart';
import 'package:sakal/features/sales/domain/repositories/sales_quotation_repository.dart';
import 'package:sakal/features/sales/presentation/providers/sales_quotation_providers.dart';
import 'package:sakal/features/sales/presentation/screens/sales_quotation_entry_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockSalesQuotationRepository extends Mock implements SalesQuotationRepository {}

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
/// a bare RichText, so match directly against the TextSpan's own plain
/// text. NOTE: every plain flutter Text widget ALSO builds down to a
/// RichText internally, so this predicate matches those too — a search
/// term that happens to be a substring of some OTHER on-screen text (e.g.
/// 'CUSTOMER' also matching the "Existing Customer" segmented-button
/// label) legitimately returns more than one match; assert the exact
/// count in that case rather than findsOneWidget.
Finder _findFieldLabel(String label) => find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText().toUpperCase().contains(label.toUpperCase()),
    );

void main() {
  late MockSalesQuotationRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
  });

  setUp(() {
    mockRepo = MockSalesQuotationRepository();
    // Every test reaches _init(), which always fetches this fixed set of
    // reference data regardless of new-vs-edit mode.
    when(() => mockRepo.getProductsForPicker(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => []);
    when(() => mockRepo.getTaxGroups(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => []);
    when(() => mockRepo.getAdditionalCharges(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => []);
    when(() => mockRepo.getUsersForAutocomplete(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => []);
    when(() => mockRepo.getSalesExecutivesForPicker(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => []);
    when(() => mockRepo.getTaxGroupMemberTaxIds(any())).thenAnswer((_) async => {});
    when(() => mockRepo.getTaxRatesByIds(
          taxIds: any(named: 'taxIds'),
          asOfDate: any(named: 'asOfDate'),
        )).thenAnswer((_) async => {});
  });

  // SalesQuotationEntryScreen's own _init() also Future.waits on
  // locationsProvider/currenciesProvider/baseCurrencyProvider/localCurrencyProvider
  // (core/providers/master_cache_providers.dart, plain FutureProviders) —
  // all have to be overridden or the real provider chain runs and hits
  // DioClient/a real datasource. accountsProvider is overridden defensively
  // too even though it's only read lazily inside the Customer picker's own
  // optionsBuilder (never invoked by these tests, which don't type into it).
  List<Override> overrides() => [
        salesQuotationRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
        accountsProvider.overrideWith((ref) async => [
              {'id': 'cust-001', 'account_code': 'CUS01', 'account_name': 'Customer One', 'account_nature': 'Customer', 'posting_allowed': true},
            ]),
        locationsProvider.overrideWith((ref) async => [
              {'id': 'loc-001', 'location_name': 'Main Warehouse'},
            ]),
        currenciesProvider.overrideWith((ref) async => [
              {'id': 'ccy-usd', 'currency_id': 'USD', 'currency_name': 'US Dollar', 'rate_decimal_places': 2},
            ]),
        baseCurrencyProvider.overrideWith((ref) async => 'USD'),
        localCurrencyProvider.overrideWith((ref) async => 'FC'),
      ];

  group('New (blank) sales quotation', () {
    testWidgets('renders the blank form with all key fields and one auto-added blank line',
        (tester) async {
      await pumpApp(tester, const SalesQuotationEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      expect(find.text('New Sales Quotation'), findsOneWidget);
      expect(find.text('Unsaved draft'), findsOneWidget);

      expect(_findFieldLabel('QUOTATION NO'), findsOneWidget);
      expect(_findFieldLabel('QUOTATION DATE'), findsOneWidget);
      expect(_findFieldLabel('VALID UNTIL'), findsOneWidget);

      // Customer-type segmented toggle.
      expect(find.text('Existing Customer'), findsOneWidget);
      expect(find.text('Prospect'), findsOneWidget);
      // 'CUSTOMER' also matches the "Existing Customer" segment label's own
      // underlying RichText, alongside the Customer field's own label.
      expect(_findFieldLabel('CUSTOMER'), findsNWidgets(2));

      expect(_findFieldLabel('LOCATION'), findsOneWidget);
      expect(_findFieldLabel('SALES PERSON'), findsOneWidget);
      expect(_findFieldLabel('PHONE'), findsOneWidget);
      expect(_findFieldLabel('EMAIL'), findsOneWidget);
      expect(_findFieldLabel('ADDRESS'), findsOneWidget);
      expect(_findFieldLabel('CURRENCY'), findsOneWidget);
      expect(_findFieldLabel('PAYMENT TERMS'), findsOneWidget);
      expect(_findFieldLabel('DELIVERY TERMS'), findsOneWidget);
      expect(_findFieldLabel('REMARKS'), findsOneWidget);

      // _init() auto-adds one blank line for a brand-new quotation — the
      // "no lines" empty state is never actually reachable on this screen.
      expect(find.text('Lines'), findsOneWidget);
      expect(find.text('No lines yet — add a product.'), findsNothing);
      expect(find.text('1. New Line'), findsOneWidget);
      expect(find.text('Add Line'), findsOneWidget);

      // Charges section is always present, even when empty.
      expect(find.text('Charges (optional)'), findsOneWidget);
      expect(find.text('No charges added.'), findsOneWidget);
      // "Add Charge" is a generic action button, unconditionally shown
      // whenever the document isn't locked — it isn't gated by whether any
      // charge-type master data has been configured yet.
      expect(find.text('Add Charge'), findsOneWidget);

      expect(find.text('Save Draft'), findsOneWidget);
      // A brand-new, never-saved quotation has no quotation number yet, so
      // no print button and no approve button (approve requires !_isNew).
      expect(find.byIcon(Icons.print_outlined), findsNothing);
      expect(find.text('Approve'), findsNothing);
    });

    testWidgets('blocks save and shows a validation message when no customer is selected', (tester) async {
      await pumpApp(tester, const SalesQuotationEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      // _saveDraft() checks the customer first (customerType defaults to
      // CUSTOMER with no customer_id picked yet), before currency/location/lines.
      expect(find.text('Select a customer, or switch to Prospect and enter their details.'), findsOneWidget);
      verifyNever(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            charges: any(named: 'charges'),
            userId: any(named: 'userId'),
          ));
    });
  });

  group('Editing an existing DRAFT (resume flow, untracked line)', () {
    void stubExistingDraft() {
      when(() => mockRepo.getHeader(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            quotationNo: any(named: 'quotationNo'),
            quotationDate: any(named: 'quotationDate'),
          )).thenAnswer((_) async => {
            'quotation_no': 'SQ-001',
            'quotation_date': '2026-07-01',
            'valid_until_date': '2026-07-16',
            'status': 'DRAFT',
            'location_id': 'loc-001',
            'customer_type': 'CUSTOMER',
            'customer_id': 'cust-001',
            'customer': {'account_code': 'CUS01', 'account_name': 'Customer One'},
            'party_name': 'Customer One',
            'party_phone': '123456',
            'party_email': 'test@example.com',
            'party_address': 'Address 1',
            'sales_person_id': 'sp-001',
            'sales_person': {'full_name': 'Sales Rep'},
            'quotation_currency_id': 'ccy-usd',
            'currency': {'currency_id': 'USD'},
            'rate_to_base': 1,
            'rate_to_local': 1,
            'payment_terms': 'Net 30',
            'delivery_terms': 'FOB',
            'remarks': 'Original remarks',
            'created_by': 'user-001',
            'approved_by': null,
          });
      when(() => mockRepo.getCustomerDetails(customerId: any(named: 'customerId')))
          .thenAnswer((_) async => null);
      when(() => mockRepo.getLines(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            quotationNo: any(named: 'quotationNo'),
            quotationDate: any(named: 'quotationDate'),
          )).thenAnswer((_) async => [
            {
              'serial_no': 1,
              'product_id': 'prod-001',
              'product': {'product_code': 'WID-A', 'product_name': 'Widget A'},
              'uom_id': 'uom-001',
              'uom': {'description': 'Piece'},
              'uom_conversion_factor': 1.0,
              'qty_pack': 10.0,
              'qty_loose': 0.0,
              'base_qty': 10.0,
              'rate': 25.0,
              'discount_percent': 0,
              'tax_group_id': null,
              'converted_qty': 0,
              'item_description': '',
              'remarks': '',
              'barcode': null,
            },
          ]);
      when(() => mockRepo.getCharges(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            quotationNo: any(named: 'quotationNo'),
            quotationDate: any(named: 'quotationDate'),
          )).thenAnswer((_) async => []);
    }

    testWidgets('loads and displays every field from the saved header and line', (tester) async {
      stubExistingDraft();

      await pumpApp(
        tester,
        const SalesQuotationEntryScreen(editQuotationNo: 'SQ-001', editQuotationDate: '2026-07-01'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      expect(find.text('Sales Quotation · SQ-001'), findsOneWidget);
      // _statusChip renders status.replaceAll('_',' ') verbatim — for a
      // still-DRAFT resumed quotation that's the literal 'DRAFT' (all
      // caps), not a title-cased 'Draft'.
      expect(find.text('DRAFT'), findsOneWidget);
      expect(find.text('[CUS01] Customer One'), findsOneWidget); // Customer autocomplete field text
      expect(find.text('Main Warehouse'), findsOneWidget); // Location dropdown
      expect(find.text('USD'), findsOneWidget); // Currency dropdown — bare currency_id, not "USD — US Dollar"
      expect(find.text('123456'), findsOneWidget); // Phone
      expect(find.text('test@example.com'), findsOneWidget); // Email
      expect(find.text('Address 1'), findsOneWidget); // Address
      expect(find.text('Net 30'), findsOneWidget); // Payment Terms
      expect(find.text('FOB'), findsOneWidget); // Delivery Terms
      expect(find.text('Original remarks'), findsOneWidget); // Remarks — not behind any collapsed section

      // Line — untracked product, single line loaded from the saved draft.
      expect(find.text('1. [WID-A] Widget A'), findsOneWidget);
      expect(find.text('Piece'), findsOneWidget);
      expect(find.text('10.0'), findsOneWidget); // qtyPackCtrl set via sl['qty_pack'].toString()
      expect(find.text('25.0'), findsOneWidget); // rateCtrl set via sl['rate'].toString()

      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.text('Approve'), findsNothing); // canApprove defaults false from the harness's empty menuProvider
      expect(find.byIcon(Icons.print_outlined), findsOneWidget); // a saved quotation is printable
    });

    testWidgets('editing remarks and saving calls the repository with the updated payload', (tester) async {
      stubExistingDraft();
      when(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            charges: any(named: 'charges'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'SQ-001');
      when(() => mockRepo.cacheQuotationLocally(
            effectiveQuotationNo: any(named: 'effectiveQuotationNo'),
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            charges: any(named: 'charges'),
          )).thenAnswer((_) async {});

      await pumpApp(
        tester,
        const SalesQuotationEntryScreen(editQuotationNo: 'SQ-001', editQuotationDate: '2026-07-01'),
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
            charges: any(named: 'charges'),
            userId: any(named: 'userId'),
          )).captured;
      final header = captured[0] as Map<String, dynamic>;
      final lines = captured[1] as List<Map<String, dynamic>>;

      expect(header['quotation_no'], 'SQ-001');
      expect(header['location_id'], 'loc-001');
      expect(header['customer_type'], 'CUSTOMER');
      expect(header['customer_id'], 'cust-001');
      expect(header['quotation_currency_id'], 'ccy-usd');
      expect(header['rate_to_base'], 1.0);
      expect(header['rate_to_local'], 1.0);
      expect(header['remarks'], 'Updated remarks');

      expect(lines, hasLength(1));
      final line = lines.first;
      expect(line['serial_no'], 1);
      expect(line['product_id'], 'prod-001');
      expect(line['uom_id'], 'uom-001');
      expect(line['uom_conversion_factor'], 1.0);
      expect(line['qty_pack'], 10.0);
      expect(line['qty_loose'], 0.0);
      expect(line['base_qty'], 10.0);
      expect(line['rate'], 25.0);
      expect(line['tax_group_id'], null); // l.taxGroupId, no '' fallback on this screen
      expect(line['barcode'], ''); // l.matchedBarcode ?? ''

      expect(find.text('Sales Quotation SQ-001 saved.'), findsOneWidget);
    });
  });

  // Same pilot pattern as Purchase Order — this screen's own two pickers:
  // Customer (header, filtering an already-resolved accountsProvider list)
  // and Product (per line, on the auto-added blank line every brand-new
  // quotation already has — see _init()'s own `_addLine()` call and the
  // "1. New Line" assertion in the blank-form render test above). Both
  // filter an ALREADY-loaded list client-side on every keystroke (Customer
  // via `ref.read(accountsProvider.future)`, already resolved/cached after
  // first read; Product via the plain `_products` list fetched once in
  // _init()) rather than calling the repository fresh per keystroke.
  group('Customer + Product autocomplete interaction (real search + select)', () {
    // Exact-match (never a bare substring) label lookup — SakalFieldCard
    // appends a child TextSpan(' *') for required fields, so a required
    // label's full toPlainText() is "LABEL *", not "LABEL". A plain
    // .contains() match would be ambiguous here too: "Customer" alone also
    // matches the "Existing Customer" segmented-button label's own RichText.
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

    testWidgets('typing into the Customer field shows the matching option, and tapping it selects the customer', (tester) async {
      // _onCustomerSelected awaits _loadCustomerInfo -> getCustomerDetails
      // even though this test doesn't assert on the credit-info display —
      // must be stubbed or the call throws (caught internally, but stubbing
      // keeps this test's intent explicit rather than relying on the
      // catch-and-ignore fallback).
      when(() => mockRepo.getCustomerDetails(customerId: any(named: 'customerId')))
          .thenAnswer((_) async => null);

      await pumpApp(tester, const SalesQuotationEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      // Default customerType is CUSTOMER (the "Existing Customer" segment
      // is already selected), so the Customer autocomplete is already the
      // field rendered — no segmented-button tap needed first.
      final customerField = fieldInCard('Customer', () => find.byType(TextFormField));
      await tester.enterText(customerField, 'Customer');
      await tester.pumpAndSettle();

      expect(find.text('[CUS01] Customer One'), findsOneWidget);

      await tester.tap(find.text('[CUS01] Customer One'));
      await tester.pumpAndSettle();

      // _onCustomerSelected sets _customerId/_customerDisplay — the field's
      // own displayed value is the simplest observable proof of selection.
      expect(find.text('[CUS01] Customer One'), findsOneWidget);
    });

    testWidgets(
        'typing into the Product field on the auto-added blank line shows the matching option, and selecting it updates the line title and unit',
        (tester) async {
      when(() => mockRepo.getProductsForPicker(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
          )).thenAnswer((_) async => [
            {
              'id': 'prod-001',
              'product_code': 'WID-A',
              'product_name': 'Widget A',
              'base_uom_id': 'uom-001',
              'uom': {'description': 'Piece'},
              'sales_tax_group_id': null,
            },
          ]);

      await pumpApp(tester, const SalesQuotationEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      // _init() auto-adds one blank line for a brand-new quotation — no
      // "Add Line" tap needed, unlike Sales Order's DIRECT mode.
      expect(find.text('1. New Line'), findsOneWidget);

      final productField = fieldInCard('Product', () => find.byType(TextFormField));
      await tester.enterText(productField, 'Widget');
      await tester.pumpAndSettle();

      expect(find.text('[WID-A] Widget A'), findsOneWidget);

      await tester.tap(find.text('[WID-A] Widget A'));
      await tester.pumpAndSettle();

      // _onProductSelected sets row.productId/productDisplay (line title, a
      // plain Text — updates on rebuild, no remount needed) and
      // row.uomLabel from the product's own nested 'uom' map. Rate is left
      // unresolved here since _resolvePrice's own _quotationCurrencyCode
      // == null guard short-circuits before any network call (no currency
      // picked in this test) — only title/unit are asserted, matching what
      // this test actually exercises.
      expect(find.text('1. [WID-A] Widget A'), findsOneWidget);
      expect(find.text('Piece'), findsOneWidget); // Unit field, readOnly
    });
  });
}
