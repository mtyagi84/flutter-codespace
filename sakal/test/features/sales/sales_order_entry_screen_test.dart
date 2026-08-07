import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/providers/master_cache_providers.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/core/widgets/sakal_field_card.dart';
import 'package:sakal/features/sales/domain/repositories/sales_order_repository.dart';
import 'package:sakal/features/sales/presentation/providers/sales_order_providers.dart';
import 'package:sakal/features/sales/presentation/screens/sales_order_entry_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockSalesOrderRepository extends Mock implements SalesOrderRepository {}

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
/// 'CUSTOMER' also matching the "Customer PO Ref" field's own label)
/// legitimately returns more than one match; assert the exact count in
/// that case rather than findsOneWidget.
Finder _findFieldLabel(String label) => find.byWidgetPredicate(
      (w) => w is RichText && w.maxLines == 1 && w.text.toPlainText().toUpperCase().contains(label.toUpperCase()),
    );

/// Forces a viewport narrower than the app's 600px mobile breakpoint —
/// flutter_test's own default (~800x600) falls on the DESKTOP side of that
/// threshold, so the Lines section's isMobile branch (SakalLineItemCard,
/// whose title carries the '${idx+1}. ...' numeric prefix — the desktop row
/// never renders that prefixed string, only the bare product value) would
/// otherwise never render; these tests were written against that
/// mobile-card shape. Tall enough (1600) that autocomplete overlays / below-
/// the-fold content still build.
void _useMobileViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  late MockSalesOrderRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
  });

  setUp(() {
    mockRepo = MockSalesOrderRepository();
    // Every test reaches _init(), which always fetches this fixed set of
    // reference data regardless of new-vs-edit mode (DIRECT scope here —
    // AGAINST_QUOTATION's own extra init calls are out of scope).
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
    when(() => mockRepo.getPaymentTerms(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => []);
    when(() => mockRepo.getIncoterms(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => []);
    when(() => mockRepo.getTaxGroupMemberTaxIds(any())).thenAnswer((_) async => {});
    when(() => mockRepo.getTaxRatesByIds(
          taxIds: any(named: 'taxIds'),
          asOfDate: any(named: 'asOfDate'),
        )).thenAnswer((_) async => {});
    // ric_user_sales_controls governance: a missing row means every
    // permission defaults false/null (never permissive) per
    // fn_save_sales_order's own coalesce-based default. Stubbed fully
    // permissive here (same shortcut the real Sales Order pgTAP tests use)
    // so a DIRECT-mode line with a manually-entered rate/discount is never
    // blocked by governance in these widget tests.
    when(() => mockRepo.getUserSalesControls(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          userId: any(named: 'userId'),
        )).thenAnswer((_) async => {
          'can_override_price': true,
          'can_give_discount': true,
          'max_discount_percent': 100,
          'can_view_cost_price': true,
        });
    // _refreshLineStockInfo (DIRECT-mode resume) fetches current
    // stock/cost per line.
    when(() => mockRepo.getProductLocationCost(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          locationId: any(named: 'locationId'),
          productId: any(named: 'productId'),
        )).thenAnswer((_) async => {'current_stock': 50, 'cost_price': 20});
  });

  // SalesOrderEntryScreen's own _init() also Future.waits on
  // locationsProvider/currenciesProvider/baseCurrencyProvider/localCurrencyProvider
  // (core/providers/master_cache_providers.dart, plain FutureProviders) —
  // all have to be overridden or the real provider chain runs and hits
  // DioClient/a real datasource. accountsProvider is overridden defensively
  // too even though it's only read lazily inside the Customer picker's own
  // optionsBuilder (never invoked by these tests, which don't type into it).
  List<Override> overrides() => [
        salesOrderRepositoryProvider.overrideWithValue(mockRepo),
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

  group('New (blank) DIRECT sales order', () {
    testWidgets('renders the blank form with all key fields and no lines yet', (tester) async {
      await pumpApp(tester, const SalesOrderEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      expect(find.text('New Sales Order'), findsOneWidget);
      expect(find.text('Unsaved draft'), findsOneWidget);

      expect(_findFieldLabel('ORDER NO'), findsOneWidget);
      expect(_findFieldLabel('ORDER DATE'), findsOneWidget);
      expect(_findFieldLabel('SALES PERSON'), findsOneWidget);
      // 'CUSTOMER' also matches the "Customer PO Ref" field's own label.
      expect(_findFieldLabel('CUSTOMER'), findsNWidgets(2));
      expect(_findFieldLabel('CUSTOMER PO REF'), findsOneWidget);
      expect(_findFieldLabel('LOCATION'), findsOneWidget);
      expect(_findFieldLabel('CURRENCY'), findsOneWidget);
      expect(_findFieldLabel('PAYMENT TERM'), findsOneWidget);
      expect(_findFieldLabel('INCOTERM'), findsOneWidget);
      expect(_findFieldLabel('SHIP TO'), findsOneWidget);
      expect(_findFieldLabel('BILL TO'), findsOneWidget);
      expect(_findFieldLabel('EXPECTED DELIVERY'), findsOneWidget);
      expect(_findFieldLabel('DELIVERY INSTRUCTIONS'), findsOneWidget);
      expect(_findFieldLabel('REMARKS'), findsOneWidget);

      // DIRECT mode does NOT auto-add a blank line on open (unlike Sales
      // Quotation) — _addLine() also hard-requires a customer to be picked
      // first, so a genuinely empty state is reachable here.
      expect(find.text('Lines'), findsOneWidget);
      expect(find.text('No lines yet.'), findsOneWidget);
      expect(find.text('Add Line'), findsOneWidget);

      // Charges section is always present, even when empty.
      expect(find.text('Charges (optional — always editable)'), findsOneWidget);
      expect(find.text('No charges added.'), findsOneWidget);
      // "Add Charge" is a generic action button, unconditionally shown
      // whenever the document isn't locked — it isn't gated by whether any
      // charge-type master data has been configured yet.
      expect(find.text('Add Charge'), findsOneWidget);

      expect(find.text('Save Draft'), findsOneWidget);
      // A brand-new, never-saved order has no order number yet, so no
      // print button, no approve button, and no cancel button.
      expect(find.byIcon(Icons.print_outlined), findsNothing);
      expect(find.text('Approve'), findsNothing);
      expect(find.text('Cancel Order'), findsNothing);
    });

    testWidgets('blocks save and shows a validation message when no customer is selected', (tester) async {
      await pumpApp(tester, const SalesOrderEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      // _saveDraft() checks the customer first, before currency/location/lines.
      expect(find.text('Select a customer.'), findsOneWidget);
      verifyNever(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            charges: any(named: 'charges'),
            userId: any(named: 'userId'),
          ));
    });
  });

  group('Editing an existing DRAFT DIRECT order (resume flow, untracked line)', () {
    void stubExistingDraft() {
      when(() => mockRepo.getHeader(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            orderNo: any(named: 'orderNo'),
            orderDate: any(named: 'orderDate'),
          )).thenAnswer((_) async => {
            'order_no': 'SO-001',
            'order_date': '2026-07-01',
            'status': 'DRAFT',
            'order_mode': 'DIRECT',
            'source_quotation_no': null,
            'source_quotation_date': null,
            'location_id': 'loc-001',
            'customer_id': 'cust-001',
            'customer': {'account_code': 'CUS01', 'account_name': 'Customer One'},
            'customer_po_ref': 'PO-REF-1',
            'ship_to': 'Ship To Address',
            'bill_to': 'Bill To Address',
            'expected_delivery_date': null,
            'sales_person_id': 'sp-001',
            'sales_person': {'full_name': 'Sales Rep'},
            'order_currency_id': 'ccy-usd',
            'currency': {'currency_id': 'USD'},
            'rate_to_base': 1,
            'rate_to_local': 1,
            'payment_term_id': null,
            'payment_term': null,
            'incoterm_id': null,
            'incoterm': null,
            'delivery_instructions': '',
            'remarks': 'Original remarks',
            'created_by': 'user-001',
            'approved_by': null,
          });
      when(() => mockRepo.getCustomerDetails(customerId: any(named: 'customerId')))
          .thenAnswer((_) async => null);
      when(() => mockRepo.getLines(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            orderNo: any(named: 'orderNo'),
            orderDate: any(named: 'orderDate'),
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
              'delivered_qty': 0,
              'price_source': 'PRICE_MASTER',
              'source_quotation_line_serial': null,
              'item_description': '',
              'price_override_reason': '',
              'remarks': '',
              'barcode': null,
            },
          ]);
      when(() => mockRepo.getCharges(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            orderNo: any(named: 'orderNo'),
            orderDate: any(named: 'orderDate'),
          )).thenAnswer((_) async => []);
    }

    testWidgets('loads and displays every field from the saved header and line', (tester) async {
      stubExistingDraft();
      _useMobileViewport(tester);

      await pumpApp(
        tester,
        const SalesOrderEntryScreen(editOrderNo: 'SO-001', editOrderDate: '2026-07-01'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      expect(find.text('Sales Order · SO-001'), findsOneWidget);
      // _buildTitleBlock calls _statusChip(_status) directly whenever
      // _orderNo != null, regardless of status value — for a still-DRAFT
      // resumed order that renders the literal 'DRAFT' (all caps).
      expect(find.text('DRAFT'), findsOneWidget);
      expect(find.text('[CUS01] Customer One'), findsOneWidget); // Customer autocomplete field text
      expect(find.text('Main Warehouse'), findsOneWidget); // Location dropdown
      expect(find.text('USD'), findsOneWidget); // Currency dropdown — bare currency_id
      expect(find.text('PO-REF-1'), findsOneWidget); // Customer PO Ref
      expect(find.text('Ship To Address'), findsOneWidget);
      expect(find.text('Bill To Address'), findsOneWidget);
      expect(find.text('Original remarks'), findsOneWidget); // Remarks — not behind any collapsed section

      // Line — untracked product, single line loaded from the saved draft.
      expect(find.text('1. [WID-A] Widget A'), findsOneWidget);
      expect(find.text('Piece'), findsOneWidget);
      expect(find.text('10.0'), findsOneWidget); // qtyPackCtrl set via sl['qty_pack'].toString()
      expect(find.text('25.0'), findsOneWidget); // rateCtrl set via sl['rate'].toString()

      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.text('Approve'), findsNothing); // canApprove defaults false from the harness's empty menuProvider
      expect(find.text('Cancel Order'), findsNothing); // showCancel also gated on canApprove
      expect(find.byIcon(Icons.print_outlined), findsOneWidget); // a saved order is printable
    });

    testWidgets('editing remarks and saving calls the repository with the updated payload', (tester) async {
      stubExistingDraft();
      when(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            charges: any(named: 'charges'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'SO-001');
      when(() => mockRepo.cacheOrderLocally(
            effectiveOrderNo: any(named: 'effectiveOrderNo'),
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            charges: any(named: 'charges'),
          )).thenAnswer((_) async {});

      await pumpApp(
        tester,
        const SalesOrderEntryScreen(editOrderNo: 'SO-001', editOrderDate: '2026-07-01'),
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

      expect(header['order_no'], 'SO-001');
      expect(header['location_id'], 'loc-001');
      expect(header['order_mode'], 'DIRECT');
      expect(header['customer_id'], 'cust-001');
      expect(header['order_currency_id'], 'ccy-usd');
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
      expect(line['tax_group_id'], null);
      expect(line['barcode'], ''); // l.matchedBarcode ?? ''
      expect(line['source_quotation_line_serial'], null); // DIRECT-mode line, never quotation-sourced

      expect(find.text('Sales Order SO-001 saved.'), findsOneWidget);
    });
  });

  // DIRECT mode's own two pickers: Customer (header, filtering an already-
  // resolved accountsProvider list) and Product (per line). Unlike Sales
  // Quotation, DIRECT mode does NOT auto-add a blank line on open, AND
  // _addLine() hard-requires a customer to already be selected (see
  // _addLine()'s own "Select a Customer first." guard) — so the Product
  // interaction test must select a customer and tap "Add Line" first
  // before a Product field even exists to type into.
  group('Customer + Product autocomplete interaction (real search + select)', () {
    // Exact-match (never a bare substring) label lookup — SakalFieldCard
    // appends a child TextSpan(' *') for required fields, so a required
    // label's full toPlainText() is "LABEL *", not "LABEL". A plain
    // .contains() match would be ambiguous here too: "Customer" alone also
    // matches the "Customer PO Ref" field's own label.
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
      when(() => mockRepo.getCustomerDetails(customerId: any(named: 'customerId')))
          .thenAnswer((_) async => null);

      await pumpApp(tester, const SalesOrderEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

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
        'after selecting a customer and adding a line, typing into the Product field shows the matching option, and selecting it updates the line title and unit',
        (tester) async {
      when(() => mockRepo.getCustomerDetails(customerId: any(named: 'customerId')))
          .thenAnswer((_) async => null);
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
              'cost_currency_id': null,
            },
          ]);

      // Needs BOTH a narrow width (<600px, to reach the isMobile branch —
      // this test asserts '1. New Line'/'1. [WID-A] Widget A', text that
      // only SakalLineItemCard renders) AND extra height: by this point in
      // the flow (Customer already picked + a line card already on
      // screen), the Product field sits low enough that its options
      // overlay renders right at the default ~600px-tall test viewport's
      // bottom edge — the overlay's own outer TapRegion barrier then wins
      // the hit-test over the specific option Text beneath it.
      // RawAutocomplete's overlay is positioned via CompositedTransformFollower
      // (screen-absolute), so it lives outside any Scrollable an
      // ensureVisible() could act on — a taller viewport is the actual fix.
      // _useMobileViewport's Size(400, 1600) satisfies both needs at once.
      _useMobileViewport(tester);

      await pumpApp(tester, const SalesOrderEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      // _addLine() hard-requires a customer to already be selected — pick
      // one first via the same Customer autocomplete driven above.
      final customerField = fieldInCard('Customer', () => find.byType(TextFormField));
      await tester.enterText(customerField, 'Customer');
      await tester.pumpAndSettle();
      await tester.tap(find.text('[CUS01] Customer One'));
      await tester.pumpAndSettle();

      expect(find.text('No lines yet.'), findsOneWidget);
      await tester.tap(find.text('Add Line'));
      await tester.pumpAndSettle();
      expect(find.text('1. New Line'), findsOneWidget);

      final productField = fieldInCard('Product', () => find.byType(TextFormField));
      await tester.enterText(productField, 'Widget');
      await tester.pumpAndSettle();

      expect(find.text('[WID-A] Widget A'), findsOneWidget);

      await tester.tap(find.text('[WID-A] Widget A'));
      await tester.pumpAndSettle();

      // _onProductSelected sets row.productId/productDisplay (line title)
      // and row.uomLabel from the product's own nested 'uom' map. Rate
      // stays unresolved/unchanged here since _resolvePrice's own
      // _orderCurrencyCode == null guard short-circuits before any network
      // call (no currency picked in this test) — only title/unit are
      // asserted, matching what this test actually exercises.
      expect(find.text('1. [WID-A] Widget A'), findsOneWidget);
      expect(find.text('Piece'), findsOneWidget); // Unit field, readOnly
    });
  });

  // AGAINST_QUOTATION mode — every prior Sales Order test batch (Phase 5)
  // deliberately exercised DIRECT mode only. Unlike Sales Invoice, this
  // screen has NO in-screen quotation picker of its own: the list screen
  // (sales_order_list_screen.dart) fetches the pickable quotation and
  // navigates here via GoRouter `extra: {'newOrderMode': 'AGAINST_QUOTATION',
  // 'sourceQuotationNo': ..., 'sourceQuotationDate': ...}`, which
  // app_router.dart threads straight into this widget's own constructor
  // params (see app_router.dart's own `salesOrderEntry` route builder) — so
  // driving this mode means constructing the widget with those params
  // directly, exactly like the router does, not simulating an in-screen
  // picker tap (there isn't one for this screen).
  group('AGAINST_QUOTATION mode — consolidating a Sales Quotation onto a new Order', () {
    void stubQuotationSource() {
      when(() => mockRepo.getCustomerDetails(customerId: any(named: 'customerId')))
          .thenAnswer((_) async => null);
      when(() => mockRepo.getQuotationHeader(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            quotationNo: any(named: 'quotationNo'),
            quotationDate: any(named: 'quotationDate'),
          )).thenAnswer((_) async => {
            'customer_id': 'cust-001',
            'customer': {'account_code': 'CUS01', 'account_name': 'Customer One'},
            'customer_type': 'CUSTOMER',
            'quotation_currency_id': 'ccy-usd',
            'currency': {'currency_id': 'USD'},
            'rate_to_base': 1,
            'rate_to_local': 1,
          });
      when(() => mockRepo.getQuotationLines(
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
              'base_qty': 10.0,
              'converted_qty': 0.0,
              'rate': 25.0,
              'discount_percent': 0,
              'tax_group_id': null,
              'item_description': '',
              'barcode': null,
            },
          ]);
      when(() => mockRepo.getQuotationCharges(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            quotationNo: any(named: 'quotationNo'),
            quotationDate: any(named: 'quotationDate'),
          )).thenAnswer((_) async => <Map<String, dynamic>>[]);
    }

    testWidgets('loads the source quotation header + line, freezing rate/discount but leaving qty editable', (tester) async {
      stubQuotationSource();
      _useMobileViewport(tester);

      await pumpApp(
        tester,
        const SalesOrderEntryScreen(
          newOrderMode: 'AGAINST_QUOTATION',
          sourceQuotationNo: 'SQ-001',
          sourceQuotationDate: '2026-07-01',
        ),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      // order_no is only assigned on Save -- still an unsaved draft, but
      // tagged with its AGAINST_QUOTATION source.
      expect(find.text('New Sales Order'), findsOneWidget);
      expect(find.text('Unsaved draft'), findsOneWidget);
      expect(find.text('From SQ-001'), findsOneWidget);

      // Customer + currency carried over from the quotation header, both
      // locked (read-only Customer field / disabled Currency dropdown)
      // since customerLocked/currencyField's own `editable` both check
      // _isAgainstQuotation.
      expect(find.text('[CUS01] Customer One'), findsOneWidget);
      expect(find.text('USD'), findsOneWidget);

      // Line — _buildQuotationLineRow's own title carries a numeric prefix
      // ('1. ...'), a DIFFERENT string from the read-only Product field's
      // own bare value text, so both can be asserted unambiguously without
      // scoping.
      expect(find.text('1. [WID-A] Widget A'), findsOneWidget);
      expect(find.text('[WID-A] Widget A'), findsOneWidget); // read-only Product field value
      expect(find.text('Piece'), findsOneWidget); // read-only Unit field value

      // "Qty to Convert" defaults to the FULL remaining (base_qty -
      // converted_qty = 10.0 - 0.0), and is genuinely editable (unlike
      // rate/discount) — see _OrderLineRow's own comment on why
      // qtyPackCtrl is repurposed as this single field in this mode.
      expect(find.text('10.0'), findsOneWidget); // "Qty to Convert" TextFormField
      expect(find.text('10.00'), findsOneWidget); // "of" read-only remaining, toStringAsFixed(2)
      expect(find.text('25.00'), findsOneWidget); // "Rate (frozen)" read-only, row.rate.toStringAsFixed(2)
      // discount_percent is 0 on this line, so 'Disc % (frozen)' doesn't render at all.
      expect(find.text('Disc % (frozen)'), findsNothing);
    });

    testWidgets('saving sends the frozen rate/discount and the (editable) converted qty, tagged with the source quotation', (tester) async {
      stubQuotationSource();
      when(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            charges: any(named: 'charges'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'SO-100');
      when(() => mockRepo.cacheOrderLocally(
            effectiveOrderNo: any(named: 'effectiveOrderNo'),
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            charges: any(named: 'charges'),
          )).thenAnswer((_) async {});

      await pumpApp(
        tester,
        const SalesOrderEntryScreen(
          newOrderMode: 'AGAINST_QUOTATION',
          sourceQuotationNo: 'SQ-001',
          sourceQuotationDate: '2026-07-01',
        ),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

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

      expect(header['order_mode'], 'AGAINST_QUOTATION');
      expect(header['source_quotation_no'], 'SQ-001');
      expect(header['source_quotation_date'], '2026-07-01');
      expect(header['customer_id'], 'cust-001');
      expect(header['order_currency_id'], 'ccy-usd');
      expect(header['location_id'], 'loc-001');

      expect(lines, hasLength(1));
      final line = lines.first;
      expect(line['product_id'], 'prod-001');
      expect(line['qty_pack'], 10.0); // the (editable) "Qty to Convert" value, defaulted to the full remaining
      expect(line['qty_loose'], 0); // no meaning in this mode -- forced 0
      expect(line['base_qty'], 10.0);
      expect(line['rate'], 25.0); // frozen, verbatim from the quotation line
      expect(line['discount_percent'], 0.0); // frozen, verbatim from the quotation line
      expect(line['source_quotation_line_serial'], 1);

      expect(find.text('Sales Order SO-100 saved.'), findsOneWidget);
    });
  });
}
