import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/layout/screen_header.dart';
import 'package:sakal/core/providers/master_cache_providers.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/core/utils/app_number_format.dart';
import 'package:sakal/core/widgets/sakal_autocomplete.dart';
import 'package:sakal/core/widgets/sakal_field_card.dart';
import 'package:sakal/features/sales/domain/repositories/sales_invoice_repository.dart';
import 'package:sakal/features/sales/presentation/providers/sales_invoice_providers.dart';
import 'package:sakal/features/sales/presentation/screens/sales_invoice_entry_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockSalesInvoiceRepository extends Mock implements SalesInvoiceRepository {}

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
      (w) => w is RichText && w.maxLines == 1 && w.text.toPlainText().toUpperCase().contains(label.toUpperCase()),
    );

/// The screen's title/subtitle/badge no longer render as body text — they're
/// posted to the shared TopBar via ScreenHeaderMixin (screen_header.dart),
/// and pumpApp() doesn't include a TopBar in its pumped tree at all. Read
/// the posted ScreenHeaderInfo back from the provider instead of searching
/// for rendered text. This screen's own subtitle is a `join(' · ')` of
/// several parts (Unsaved/Cash-Credit/From-quotation/From-order) — assert
/// the full joined string, not a fragment.
ScreenHeaderInfo? _readHeader(WidgetTester tester, Finder screenFinder) =>
    ProviderScope.containerOf(tester.element(screenFinder)).read(screenHeaderProvider);

void main() {
  late MockSalesInvoiceRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
  });

  setUp(() {
    mockRepo = MockSalesInvoiceRepository();
    // Every test reaches _init(), which always fetches this fixed set of
    // reference data regardless of new-vs-edit mode — see _init()'s own
    // Future.wait([...6 items...]) plus the unconditional
    // getQuickInvoiceSetup() call right after it.
    when(() => mockRepo.getUserSalesControls(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          userId: any(named: 'userId'),
        )).thenAnswer((_) async => {
          'can_override_price': true,
          'can_give_discount': true,
          'max_discount_percent': 100.0,
        });
    when(() => mockRepo.getTaxGroups(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => <Map<String, dynamic>>[]);
    when(() => mockRepo.getUsersForAutocomplete(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => [
          {'id': 'user-001', 'full_name': 'Test User'},
        ]);
    when(() => mockRepo.getAdditionalCharges(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => <Map<String, dynamic>>[]);
    when(() => mockRepo.getSalesExecutivesForPicker(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => <Map<String, dynamic>>[]);
    when(() => mockRepo.getTaxGroupMemberTaxIds(any())).thenAnswer((_) async => <String, List<String>>{});
    // _buildLineTile's Product SakalAutocomplete calls this unconditionally
    // on every field focus/change, even in tests that never intend to
    // search products — an unstubbed call throws (mocktail returns null
    // for an unstubbed Future-returning method), so every test needs this
    // default; tests that DO need real search results add their own
    // more specific when() after this, which takes precedence.
    when(() => mockRepo.getProductsForPicker(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
        )).thenAnswer((_) async => <Map<String, dynamic>>[]);
    when(() => mockRepo.getTaxRatesByIds(
          taxIds: any(named: 'taxIds'),
          asOfDate: any(named: 'asOfDate'),
        )).thenAnswer((_) async => <String, double>{});
    // Quick Invoice Setup — resolved for a Cash sale in _applyCashCustomer()
    // (DIRECT-new-invoice path only; a resumed DRAFT overwrites customer
    // fields straight from its own saved header instead, but _init() always
    // calls this regardless of new-vs-edit).
    when(() => mockRepo.getQuickInvoiceSetup(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          userId: any(named: 'userId'),
        )).thenAnswer((_) async => {
          'location_id': 'loc-001',
          'location': {'location_name': 'Main Warehouse'},
          'cash_customer_id': 'cust-001',
          'cash_customer': {'account_code': 'CUS01', 'account_name': 'Cash Customer'},
          'default_sales_person_id': null,
          'default_sales_person': null,
        });
  });

  // _init()/_applyCashCustomer()/_resolveCurrencyForCustomer() also
  // Future.wait on currenciesProvider/baseCurrencyProvider/localCurrencyProvider
  // (core/providers/master_cache_providers.dart, plain FutureProviders) — all
  // have to be overridden or the real provider chain runs and hits
  // DioClient/a real datasource. Base and local currency are deliberately
  // set to the SAME code (USD) so neither "Rate to Base"/"Rate to Local"
  // field ever renders (both are gated on invoiceCurrencyCode != that
  // currency) — out of scope per the task brief, which excludes any
  // multi-currency mechanics.
  List<Override> overrides() => [
        salesInvoiceRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
        currenciesProvider.overrideWith((ref) async => [
              {'id': 'ccy-usd', 'currency_id': 'USD', 'currency_name': 'US Dollar', 'rate_decimal_places': 2},
            ]),
        baseCurrencyProvider.overrideWith((ref) async => 'USD'),
        localCurrencyProvider.overrideWith((ref) async => 'USD'),
      ];

  group('New (blank) invoice — DIRECT + CASH', () {
    testWidgets('renders the blank form with all key fields, one auto-seeded blank line, and no print/cancel', (tester) async {
      // This screen's body is a CustomScrollView/SliverList — content below
      // the fold (the Charges card, past the header + one line row) isn't
      // actually built into the tree at the default ~600px test viewport,
      // only scheduled to build near the viewport/cache extent. A taller
      // viewport keeps everything asserted below within the initial build.
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpApp(tester, const SalesInvoiceEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      final header = _readHeader(tester, find.byType(SalesInvoiceEntryScreen));
      expect(header?.title, 'New Quick Invoice');
      expect(header?.subtitle, 'Unsaved · Cash Sale');

      // Mode + Sale Type SegmentedButtons — only rendered `if (_isNew)`.
      expect(find.text('Direct'), findsOneWidget);
      expect(find.text('Against Quotation'), findsOneWidget);
      expect(find.text('Against Order'), findsOneWidget);
      expect(find.text('Cash'), findsOneWidget);
      expect(find.text('Credit'), findsOneWidget);

      expect(_findFieldLabel('LOCATION'), findsOneWidget);
      // "Customer" label, "Walk-in Customer Name (optional)" label, AND the
      // Customer field's own read-only value "[CUS01] Cash Customer" all
      // contain the substring CUSTOMER — a genuine 3-way match, not 1.
      expect(_findFieldLabel('CUSTOMER'), findsNWidgets(3));
      expect(_findFieldLabel('SALES PERSON'), findsOneWidget);
      expect(_findFieldLabel('MOBILE'), findsOneWidget);
      expect(_findFieldLabel('ADDRESS'), findsOneWidget);
      expect(_findFieldLabel('INVOICE DATE'), findsOneWidget);
      // "Currency" label, plus "Collected — Local Currency" and "Collected
      // — Base Currency" (Collect Payment section, further down the page —
      // only actually built into the tree now that the taller test
      // viewport brings it within the Sliver's build range) all contain
      // the substring CURRENCY.
      expect(_findFieldLabel('CURRENCY'), findsNWidgets(3));
      expect(_findFieldLabel('HEADER DISCOUNT'), findsOneWidget);

      expect(find.text('Main Warehouse'), findsOneWidget); // Location, from Quick Invoice Setup
      expect(find.text('[CUS01] Cash Customer'), findsOneWidget); // Customer, resolved from cash setup
      expect(find.text('— None —'), findsOneWidget); // Sales Person dropdown, no default configured
      expect(find.text('USD'), findsOneWidget); // Currency read-only value

      // One auto-seeded blank line — this screen has no separate "Line
      // Items" card/title any more (redesigned away, see CLAUDE.md's
      // 2026-07-18 UI pass); each line is its own SakalLineItemCard.
      // The 'New Line' fallback title only renders on the mobile branch
      // (Responsive.isMobile, <600px) — the default ~800px test viewport
      // hits the desktop row layout instead, which has no title text at
      // all, so assert on the always-present Product field label instead.
      // The per-line SakalFieldCard's own "Product" label is ALSO gated
      // `showLabel: isMobile` (redundant with the desktop table header)
      // and isn't built at this viewport either — check the desktop table
      // header's own "Product" label instead (no " *" suffix there —
      // that's a SakalFieldCard-only decoration).
      expect(find.text('Product'), findsOneWidget);

      // Charges: always present and always editable for a new DIRECT
      // invoice, regardless of whether any charge types are configured —
      // unlike GRN/PO, "Add Charge" here is gated only on `!chargesLocked`,
      // never on _additionalCharges being non-empty.
      expect(find.text('Charges (optional)'), findsOneWidget);
      expect(find.text('No charges added.'), findsOneWidget);
      expect(find.text('Add Charge'), findsOneWidget);

      // Collect Payment — shown because session.quickInvoiceCollectCash
      // defaults true.
      expect(find.text('Collect Payment'), findsOneWidget);

      expect(find.text('Save Invoice'), findsOneWidget);
      // Desktop consolidates Save/Cancel/Print into the TopBar via
      // SakalHeaderActionButton (see buildScreenHeader) — a brand-new,
      // never-saved invoice has no invoice number yet, so no Print button;
      // Cancel is gated on `!isOffline && status==DRAFT && canApprove &&
      // !_isNew` — _isNew alone already rules it out here. Save Invoice
      // itself IS shown (canSaveNow true for a new DRAFT), so actions holds
      // exactly that one button.
      expect(header?.actions.length, 1);
      expect(find.text('Cancel'), findsNothing);
    });

    testWidgets('blocks save and shows a validation message when no line has a product', (tester) async {
      await pumpApp(tester, const SalesInvoiceEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save Invoice'));
      await _pumpBriefly(tester);

      // _saveAndApprove() resolves customer/currency/location from the
      // Quick Invoice Setup fixture without error, so the first real
      // failure is the auto-seeded line still having no product selected.
      expect(find.text('Add at least one line with a product and quantity.'), findsOneWidget);
      verifyNever(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            charges: any(named: 'charges'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            userId: any(named: 'userId'),
          ));
    });
  });

  group('Editing an existing DRAFT (resume flow, DIRECT + CASH, untracked line)', () {
    void stubExistingDraft() {
      when(() => mockRepo.getHeader(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            invoiceNo: any(named: 'invoiceNo'),
            invoiceDate: any(named: 'invoiceDate'),
          )).thenAnswer((_) async => {
            'invoice_no': 'SI-001',
            'invoice_date': '2026-07-20',
            'invoice_mode': 'DIRECT',
            'sale_type': 'CASH',
            'status': 'DRAFT',
            'created_by': 'user-001',
            'approved_by': null,
            'quotation_no': null, 'quotation_date': null,
            'order_no': null, 'order_date': null,
            'customer_id': 'cust-001',
            'customer': {'account_code': 'CUS01', 'account_name': 'Cash Customer'},
            'party_name': 'Walk-in Joe',
            'party_phone': '123456',
            'party_address': 'Addr 1',
            'sales_person_id': null,
            'sales_person': null,
            'location_id': 'loc-001',
            'location': {'location_name': 'Main Warehouse'},
            'invoice_currency_id': 'ccy-usd',
            'currency': {'currency_id': 'USD'},
            'rate_to_base': 1,
            'rate_to_local': 1,
            'discount_percent': 0,
            'remarks': 'Original remarks',
            'stock_dispatch_mode': 'IMMEDIATE',
            'cash_collection_mode': 'IMMEDIATE',
            'collected_amount_local': null,
            'collected_amount_base': null,
            'sales_voucher_no': null, 'sales_voucher_date': null,
            'cos_voucher_no': null, 'cos_voucher_date': null,
            'local_receipt_voucher_no': null, 'local_receipt_voucher_date': null,
            'base_receipt_voucher_no': null, 'base_receipt_voucher_date': null,
          });
      when(() => mockRepo.getLines(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            invoiceNo: any(named: 'invoiceNo'),
            invoiceDate: any(named: 'invoiceDate'),
          )).thenAnswer((_) async => [
            {
              'product': {'product_code': 'WID-A', 'product_name': 'Widget A', 'tracking_type': 'NONE'},
              'product_id': 'prod-001',
              'uom_id': 'uom-001',
              'uom': {'description': 'Piece'},
              'uom_conversion_factor': 1.0,
              'tax_group_id': null,
              'tax_group': null,
              'price_source': 'PRICE_MASTER',
              'price_source_entry_no': null,
              'discount_given_by': null,
              'discount_giver': null,
              'source_quotation_line_serial': null,
              'source_order_line_serial': null,
              'item_description': '',
              'barcode': null,
              'qty_pack': 10.0,
              'qty_loose': 0.0,
              'rate': 25.0,
              'discount_percent': 0.0,
              'price_override_reason': '',
              'remarks': '',
            },
          ]);
      when(() => mockRepo.getCharges(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            invoiceNo: any(named: 'invoiceNo'),
            invoiceDate: any(named: 'invoiceDate'),
          )).thenAnswer((_) async => <Map<String, dynamic>>[]);
    }

    testWidgets('loads and displays every field from the saved header and line', (tester) async {
      stubExistingDraft();

      await pumpApp(
        tester,
        const SalesInvoiceEntryScreen(editInvoiceNo: 'SI-001', editInvoiceDate: '2026-07-20'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      final header = _readHeader(tester, find.byType(SalesInvoiceEntryScreen));
      expect(header?.title, 'Quick Invoice · SI-001');
      expect(header?.badgeText, 'DRAFT'); // status chip
      expect(header?.subtitle, 'Cash Sale');
      // New Invoice mode/type SegmentedButtons are only rendered `if
      // (_isNew)` — a resumed, already-saved invoice never shows them.
      expect(find.text('Direct'), findsNothing);

      expect(find.text('[CUS01] Cash Customer'), findsOneWidget); // Customer, read-only for Cash
      expect(find.text('Main Warehouse'), findsOneWidget); // Location
      expect(find.text('20 Jul 2026'), findsOneWidget); // Invoice Date
      expect(find.text('USD'), findsOneWidget); // Currency read-only value
      expect(find.text('Walk-in Joe'), findsOneWidget); // Walk-in Customer Name
      expect(find.text('123456'), findsOneWidget); // Mobile
      expect(find.text('Addr 1'), findsOneWidget); // Address
      expect(find.text('Original remarks'), findsOneWidget);

      // Line — tracking_type NONE, so no batch/serial editor renders.
      // Unlike GRN/PO/Sales Delivery, this screen's own _buildLineTile
      // never renders a UOM/Unit text anywhere (uomLabel is set on the row
      // model but only ever read by _buildPrintDocument() for printing) —
      // so there is deliberately no "Piece" assertion here.
      expect(find.text('[WID-A] Widget A'), findsOneWidget);
      expect(find.text('10.0'), findsOneWidget); // qtyPackCtrl set via '${m['qty_pack']}'
      // qtyLooseCtrl AND discountPctCtrl both show '0.0' from this fixture's
      // qty_loose/discount_percent, both defaulting to 0.
      expect(find.text('0.0'), findsNWidgets(2));
      // Rate renders through SakalFormattedNumberField (AppNumberFormat.rate),
      // not the raw controller text — USD's rate_decimal_places=2 formats
      // the fixture's 25.0 as '25.00'.
      expect(find.text('25.00'), findsOneWidget); // rateCtrl
      expect(find.text('—'), findsOneWidget); // Tax field — no tax_group_id on this line
      expect(find.text('250.00'), findsOneWidget); // Amount — baseQty(10) * rate(25), no tax/discount/charges

      expect(find.text('Save Invoice'), findsOneWidget);
      expect(find.text('Cancel'), findsNothing); // canApprove defaults false from the harness's empty menuProvider
      // Desktop TopBar now holds both Save Invoice (canSaveNow true — still
      // DRAFT) and Print (invoiceNo != null) via SakalHeaderActionButton.
      expect(header?.actions.length, 2);
    });

    testWidgets('editing remarks and saving calls the repository with the updated payload', (tester) async {
      stubExistingDraft();
      when(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            charges: any(named: 'charges'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'SI-001');
      when(() => mockRepo.approve(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            invoiceNo: any(named: 'invoiceNo'),
            invoiceDate: any(named: 'invoiceDate'),
            approvedBy: any(named: 'approvedBy'),
          )).thenAnswer((_) async {});

      await pumpApp(
        tester,
        const SalesInvoiceEntryScreen(editInvoiceNo: 'SI-001', editInvoiceDate: '2026-07-20'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.text('Original remarks'), 'Updated remarks');
      await tester.tap(find.text('Save Invoice'));
      await _pumpBriefly(tester);

      final captured = verify(() => mockRepo.save(
            header: captureAny(named: 'header'),
            lines: captureAny(named: 'lines'),
            charges: any(named: 'charges'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            userId: any(named: 'userId'),
          )).captured;
      final header = captured[0] as Map<String, dynamic>;
      final lines = captured[1] as List<Map<String, dynamic>>;

      expect(header['client_id'], 'client-001');
      expect(header['company_id'], 'company-001');
      expect(header['location_id'], 'loc-001');
      expect(header['invoice_no'], 'SI-001');
      expect(header['invoice_date'], '2026-07-20');
      expect(header['invoice_mode'], 'DIRECT');
      expect(header['sale_type'], 'CASH');
      expect(header['customer_id'], 'cust-001');
      expect(header['invoice_currency_id'], 'ccy-usd');
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
      expect(line['tax_group_id'], null); // e.value.taxGroupId, no `?? ''` fallback on this screen
      expect(line['barcode'], ''); // e.value.matchedBarcode ?? ''

      expect(find.text('Sales Invoice SI-001 completed.'), findsOneWidget);
    });
  });

  // Every prior Sales Invoice test batch (Phase 5) deliberately excluded
  // driving SakalAutocomplete through real user interaction — this group
  // drives the screen's own two pickers, Customer (header) and Product
  // (per line). The default fixture is DIRECT + CASH, where Customer is a
  // plain read-only SakalFieldCard.readOnly (resolved from Quick Invoice
  // Setup, no picker to drive at all) — see the screen's own
  // `(_saleType == 'CREDIT' && !_isAgainstSource) ? SakalAutocomplete... :
  // SakalFieldCard.readOnly` branch around _buildCashHeaderSection's
  // sibling. Switching to Credit via the Cash/Credit SegmentedButton is
  // what turns it into a real, drivable field. Both pickers call the
  // repository ASYNCHRONOUSLY per keystroke: Customer via
  // `accountsProvider.future` (a cached FutureProvider, filtered
  // client-side once resolved) and Product via
  // `ds.getProductsForPicker(..., search: v.text)` (a real per-keystroke
  // repository call, unlike GRN's own client-side `_searchField` helper) —
  // pumpAndSettle() after typing lets either resolve before the overlay's
  // filtered options are asserted.
  group('Customer + Product autocomplete interaction (real search + select, DIRECT + CREDIT)', () {
    // Stricter than a plain "contains" label match — see
    // grn_entry_screen_test.dart's own identical helper for the full
    // rationale (SakalFieldCard appends a child TextSpan(' *') for required
    // fields, and a bare `.contains()` match on "Customer" would also hit
    // "Walk-in Customer Name (optional)" in Cash mode).
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

    // accountsProvider isn't in the base overrides() (no test needed it
    // until now — the CASH-mode fixture never touches it) — added only for
    // this group, via spread, so the other 6 tests above stay unaffected.
    List<Override> creditOverrides() => [
          ...overrides(),
          accountsProvider.overrideWith((ref) async => [
                {'id': 'cust-002', 'account_code': 'CUS-002', 'account_name': 'Acme Corp', 'account_nature': 'Customer', 'posting_allowed': true},
              ]),
        ];

    testWidgets('switching to Credit shows an editable Customer field; typing and selecting a customer updates the display', (tester) async {
      when(() => mockRepo.getCustomerDetails(customerId: any(named: 'customerId')))
          .thenAnswer((_) async => {'rim_currencies': {'currency_id': 'USD'}});

      await pumpApp(tester, const SalesInvoiceEntryScreen(), overrides: creditOverrides(), session: testSession());
      await tester.pumpAndSettle();

      // Default is Cash, where Customer is read-only (resolved from Quick
      // Invoice Setup) — switch to Credit first, which is what makes the
      // field a real, drivable SakalAutocomplete. The Sale Type
      // SegmentedButton is only rendered `if (_isNew)`, true here.
      await tester.tap(find.text('Credit'));
      await tester.pumpAndSettle();

      final customerField = fieldInCard('Customer', () => find.byType(TextFormField));
      await tester.enterText(customerField, 'Acme');
      // optionsBuilder awaits accountsProvider.future then filters
      // client-side — pumpAndSettle resolves that Future and lets
      // RawAutocomplete's OverlayEntry render the filtered options.
      await tester.pumpAndSettle();

      expect(find.text('[CUS-002] Acme Corp'), findsOneWidget);

      await tester.tap(find.text('[CUS-002] Acme Corp'));
      await tester.pumpAndSettle();

      // onSelected sets _customerId/_customerDisplay — RawAutocomplete's
      // own field controller already reflects the selection text (this
      // screen doesn't key the Customer field to _customerDisplay, so no
      // remount is even needed for this to show up), directly observable
      // without saving and inspecting a payload.
      expect(find.text('[CUS-002] Acme Corp'), findsOneWidget);
    });

    testWidgets('selecting a Customer then a Product on the auto-seeded line resolves price and updates the line title and rate', (tester) async {
      when(() => mockRepo.getCustomerDetails(customerId: any(named: 'customerId')))
          .thenAnswer((_) async => {'rim_currencies': {'currency_id': 'USD'}});
      when(() => mockRepo.getProductsForPicker(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            search: any(named: 'search'),
          )).thenAnswer((_) async => [
            {
              'id': 'prod-001',
              'product_code': 'WID-A',
              'product_name': 'Widget A',
              'base_uom_id': 'uom-001',
              'uom': {'description': 'Piece'},
              'tracking_type': 'NONE',
              'sales_tax_group_id': null,
            },
          ]);
      when(() => mockRepo.getActivePrice(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            locationId: any(named: 'locationId'),
            productId: any(named: 'productId'),
            uomId: any(named: 'uomId'),
            customerId: any(named: 'customerId'),
            asOfDate: any(named: 'asOfDate'),
            currencyCode: any(named: 'currencyCode'),
          )).thenAnswer((_) async => {'selling_price': 42.5, 'entry_no': 'PM-001'});

      // The Product options overlay renders below the default ~600px-tall
      // test viewport once Customer is already picked (confirmed: a prior
      // run reported the tap offset as literally outside Size(800, 600)) —
      // a taller viewport keeps it on-screen and hit-testable.
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpApp(tester, const SalesInvoiceEntryScreen(), overrides: creditOverrides(), session: testSession());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Credit'));
      await tester.pumpAndSettle();

      final customerField = fieldInCard('Customer', () => find.byType(TextFormField));
      await tester.enterText(customerField, 'Acme');
      await tester.pumpAndSettle();
      // tester.tap(find.text(...)) taps the center of the raw option text,
      // which can land outside its own hit area inside the overlay's
      // InkWell — same class of unreliable-tap issue already documented
      // and worked around below for the Product field (Enter-to-select).
      // A freshly-populated options list always pre-highlights index 0,
      // and with only one matching customer in this fixture, Enter selects
      // it directly, sidestepping the overlay hit-test entirely.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      // Before any product is picked, the auto-seeded blank line's own
      // title falls back to 'New Line' (`row.productDisplay.isEmpty ?
      // 'New Line' : row.productDisplay`) — but only on the mobile branch
      // (Responsive.isMobile, <600px); the default ~800px test viewport
      // hits the desktop row layout, which has no title text at all. The
      // per-line SakalFieldCard's own "Product" label is ALSO gated
      // `showLabel: isMobile` and isn't built at this viewport either —
      // check the desktop table header's own "Product" label instead (no
      // " *" suffix there — that's a SakalFieldCard-only decoration).
      expect(find.text('Product'), findsOneWidget);

      // Can't use fieldInCard() here either, for the same reason — the
      // per-line Product field's own label isn't built at this viewport,
      // so there's no in-card label to anchor an ancestor lookup on.
      // Desktop has no per-line SakalLineItemCard to scope into either (see
      // CLAUDE.md's "Line-items grid" pattern — that's mobile-only here,
      // desktop is a plain Container row with no distinguishing ancestor
      // type). Customer's own picker also uses
      // SakalAutocomplete<Map<String, dynamic>> and is built earlier in the
      // tree (header, above the Lines section) — .last reliably resolves
      // to the one auto-seeded line's Product field.
      final productField = find.descendant(of: find.byType(SakalAutocomplete<Map<String, dynamic>>), matching: find.byType(TextFormField)).last;
      await tester.enterText(productField, 'Widget');
      await tester.pumpAndSettle();

      expect(find.text('[WID-A] Widget A'), findsOneWidget);

      // This screen's body is a CustomScrollView/SliverList, which put the
      // options overlay at a screen position where a Sliver content layer
      // won the hit-test over it — tapping the option was never reliable
      // here. SakalAutocomplete supports Enter-to-select instead (its own
      // documented keyboard-navigation feature): a freshly-populated
      // options list always pre-highlights index 0, and with only one
      // matching product in this fixture, Enter selects it directly,
      // sidestepping the overlay hit-test entirely.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      // _onProductSelected sets row.productId/productDisplay (used
      // directly as the SakalLineItemCard's own title, a plain Text that
      // updates on every rebuild) and, since a customer + currency were
      // already resolved above, calls _resolvePrice -> getActivePrice ->
      // row.rateCtrl.text = '42.5'. The Rate field is a
      // SakalFormattedNumberField wrapping that controller: its own
      // display controller reformats synchronously the moment the
      // underlying controller's text changes (a real ChangeNotifier
      // listener, not something that waits for a rebuild), so the widget
      // actually rendered shows the grouped/rounded "42.50", not the raw
      // "42.5" the repository returned.
      expect(find.text('[WID-A] Widget A'), findsOneWidget);
      // Can't use fieldInCard('Rate', ...) here — the per-line Rate field's
      // own label isn't built at this (non-mobile) viewport either. The
      // formatted value is itself the observable proof the price resolved.
      expect(find.text('42.50'), findsOneWidget);
    });
  });

  // AGAINST_QUOTATION mode — every prior Sales Invoice test batch (Phase 5)
  // deliberately exercised DIRECT mode only. Unlike Sales Order (whose mode
  // is chosen entirely on the LIST screen, with no in-screen picker at
  // all), Sales Invoice's own mode selector AND its quotation/order picker
  // dialog both live on THIS screen (the 2026-07-18 UI pass moved them
  // here — see _pickQuotation/_onModeSegmentChanged) — so this is a
  // genuine "drive the SegmentedButton, then tap a real picker dialog"
  // interaction test, not just constructing the widget with a pre-set
  // mode/source param the way the Sales Order test above has to.
  group('AGAINST_QUOTATION mode — switching via the SegmentedButton and picking a source quotation', () {
    // Same helper as the group above, redefined locally per this file's
    // own established convention (each group owns its copy).
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

    testWidgets('picking a quotation from the dialog switches to CREDIT and consolidates its line, frozen and read-only', (tester) async {
      // This test's later assertions use fieldInCard() to scope per-line
      // Product/Quantity/Tax/Rate values (some, like '—', aren't unique
      // plain text on screen) — those per-line SakalFieldCard labels are
      // gated `showLabel: isMobile` and need a genuinely mobile viewport to
      // be built at all. Safe here (unlike the DIRECT+CREDIT interaction
      // test above) because no per-line autocomplete typing happens after
      // the quotation loads — the line is frozen/read-only by that point.
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      when(() => mockRepo.getInvoiceableQuotations(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
          )).thenAnswer((_) async => [
            {
              'quotation_no': 'SQ-001',
              'quotation_date': '2026-07-01',
              'customer': {'account_code': 'CUS01', 'account_name': 'Customer One'},
              'customer_type': 'CUSTOMER',
              'status': 'APPROVED',
              'grand_total': 250.0,
            },
          ]);
      when(() => mockRepo.getQuotationHeader(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            quotationNo: any(named: 'quotationNo'),
            quotationDate: any(named: 'quotationDate'),
          )).thenAnswer((_) async => {
            'customer_id': 'cust-001',
            'customer': {'account_code': 'CUS01', 'account_name': 'Customer One'},
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
              'product': {'product_code': 'WID-A', 'product_name': 'Widget A', 'tracking_type': 'NONE'},
              'uom_id': 'uom-001',
              'uom': {'description': 'Piece'},
              'uom_conversion_factor': 1.0,
              'base_qty': 10.0,
              'rate': 25.0,
              'discount_percent': 0.0,
              'tax_group_id': null,
              'tax_group': null,
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

      await pumpApp(tester, const SalesInvoiceEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      // Starts in DIRECT + CASH — the screen's own default for a brand-new
      // invoice (_init()'s own else-branch when no newInvoiceMode is passed).
      var header = _readHeader(tester, find.byType(SalesInvoiceEntryScreen));
      expect(header?.subtitle, 'Unsaved · Cash Sale');

      // The 3-segment Mode SegmentedButton (Direct/Against Quotation/Against
      // Order) sits in the same Wrap row as the 2-segment Sale Type button
      // — at the default ~800px test width the hit-test framework can
      // report the tap offset as landing on an ink/overlay layer rather
      // than this segment's own gesture region; ensureVisible + an explicit
      // settle pump first, and warnIfMissed:false since the pointer event
      // is still delivered at the computed offset regardless of the
      // (frequently-false-positive) warning.
      await tester.ensureVisible(find.text('Against Quotation'));
      await tester.pump();
      await tester.tap(find.text('Against Quotation'), warnIfMissed: false);
      await tester.pumpAndSettle();

      // _hasUnsavedWork is false at this point (the auto-seeded blank line
      // has no product yet, remarks are empty), so _confirmDiscardIfDirty()
      // returns immediately and _pickQuotation()'s own SimpleDialog shows
      // straight away, listing the fixture quotation.
      expect(find.text('Select a Sales Quotation'), findsOneWidget);
      expect(find.text('SQ-001'), findsOneWidget);
      await tester.tap(find.text('SQ-001'));
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      // _loadFromQuotation always forces a CREDIT sale and carries the
      // source's own customer/currency verbatim; the picked doc number now
      // shows as a Chip next to the mode selector (dialog is closed, so
      // this is the only remaining match).
      header = _readHeader(tester, find.byType(SalesInvoiceEntryScreen));
      expect(header?.subtitle, 'Unsaved · Credit Sale · From SQ-001');
      expect(find.text('SQ-001'), findsOneWidget);
      expect(find.text('[CUS01] Customer One'), findsOneWidget); // read-only Customer field
      expect(find.text('USD'), findsOneWidget); // read-only Currency field

      // Line — re-derived server-side from the source quotation, copied
      // verbatim: product/qty land correctly, and Rate is genuinely
      // disabled (frozen), not merely visually similar to a normal field.
      // Product duplicates onto BOTH the mobile card's own title (no
      // numeric prefix on THIS screen, unlike Sales Order's own
      // '${idx+1}. ...' convention) AND the read-only Product field's own
      // value — scoped to the Product-labelled card specifically to avoid
      // over/under-counting either one.
      expect(fieldInCard('Product', () => find.text('[WID-A] Widget A')), findsOneWidget);
      // showLooseQty is forced off for an against-source line, so the
      // label is the bare 'Quantity', not 'Qty Pack'.
      expect(fieldInCard('Quantity', () => find.text('10.0')), findsOneWidget);
      expect(fieldInCard('Tax', () => find.text('—')), findsOneWidget); // no tax_group_id on this line

      final rateField = fieldInCard('Rate', () => find.byType(TextFormField));
      final rateWidget = tester.widget<TextFormField>(rateField);
      // Rate renders through SakalFormattedNumberField, whose own display
      // controller shows a GROUPED/rounded value, not the raw controller
      // text (same distinction the DIRECT+CREDIT interaction test above
      // relies on for its own Rate-field assertion) — computed here via
      // the actual production formatter rather than hardcoding a guess at
      // its exact output.
      expect(rateWidget.controller!.text, AppNumberFormat.rate(25.0, decimalPlaces: 2, numberFormatStyle: 'INTERNATIONAL'));
      expect(rateWidget.enabled, false); // frozen — never editable in this mode

      // Charges card is present but explicitly read-only in this mode (the
      // server copies the source document's own charges verbatim
      // regardless of what's shown here).
      expect(find.text('Charges (carried forward from source — read-only)'), findsOneWidget);
    });
  });
}
