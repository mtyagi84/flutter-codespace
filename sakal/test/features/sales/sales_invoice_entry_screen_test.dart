import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/providers/master_cache_providers.dart';
import 'package:sakal/core/sync/sync_engine.dart';
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
      (w) => w is RichText && w.text.toPlainText().toUpperCase().contains(label.toUpperCase()),
    );

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
      await pumpApp(tester, const SalesInvoiceEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      expect(find.text('New Quick Invoice'), findsOneWidget);
      expect(find.text('Unsaved'), findsOneWidget);
      expect(find.text('Cash Sale'), findsOneWidget);

      // Mode + Sale Type SegmentedButtons — only rendered `if (_isNew)`.
      expect(find.text('Direct'), findsOneWidget);
      expect(find.text('Against Quotation'), findsOneWidget);
      expect(find.text('Against Order'), findsOneWidget);
      expect(find.text('Cash'), findsOneWidget);
      expect(find.text('Credit'), findsOneWidget);

      expect(_findFieldLabel('LOCATION'), findsOneWidget);
      // "Customer" and "Walk-in Customer Name (optional)" both contain the
      // substring CUSTOMER — a genuine 2-way match, not 1.
      expect(_findFieldLabel('CUSTOMER'), findsNWidgets(2));
      expect(_findFieldLabel('SALES PERSON'), findsOneWidget);
      expect(_findFieldLabel('MOBILE'), findsOneWidget);
      expect(_findFieldLabel('ADDRESS'), findsOneWidget);
      expect(_findFieldLabel('INVOICE DATE'), findsOneWidget);
      expect(_findFieldLabel('CURRENCY'), findsOneWidget);
      expect(_findFieldLabel('HEADER DISCOUNT'), findsOneWidget);

      expect(find.text('Main Warehouse'), findsOneWidget); // Location, from Quick Invoice Setup
      expect(find.text('[CUS01] Cash Customer'), findsOneWidget); // Customer, resolved from cash setup
      expect(find.text('— None —'), findsOneWidget); // Sales Person dropdown, no default configured
      expect(find.text('USD'), findsOneWidget); // Currency read-only value

      // One auto-seeded blank line — this screen has no separate "Line
      // Items" card/title any more (redesigned away, see CLAUDE.md's
      // 2026-07-18 UI pass); each line is its own SakalLineItemCard.
      expect(find.text('New Line'), findsOneWidget);

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
      // A brand-new, never-saved invoice has no invoice number yet, so no
      // print button; Cancel is gated on `!isOffline && status==DRAFT &&
      // canApprove && !_isNew` — _isNew alone already rules it out here.
      expect(find.byIcon(Icons.print_outlined), findsNothing);
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

      expect(find.text('Quick Invoice · SI-001'), findsOneWidget);
      expect(find.text('DRAFT'), findsOneWidget); // status chip
      expect(find.text('Cash Sale'), findsOneWidget);
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
      expect(find.text('0.0'), findsOneWidget); // qtyLooseCtrl
      expect(find.text('25.0'), findsOneWidget); // rateCtrl
      expect(find.text('—'), findsOneWidget); // Tax field — no tax_group_id on this line
      expect(find.text('250.00'), findsOneWidget); // Amount — baseQty(10) * rate(25), no tax/discount/charges

      expect(find.text('Save Invoice'), findsOneWidget);
      expect(find.text('Cancel'), findsNothing); // canApprove defaults false from the harness's empty menuProvider
      expect(find.byIcon(Icons.print_outlined), findsOneWidget); // a saved invoice is printable
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
}
