import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/config/master_type_keys.dart';
import 'package:sakal/core/providers/master_cache_providers.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/core/widgets/sakal_field_card.dart';
import 'package:sakal/features/purchase/data/models/po_charge_line_model.dart';
import 'package:sakal/features/purchase/data/models/po_payment_term_model.dart';
import 'package:sakal/features/purchase/data/models/purchase_order_line_model.dart';
import 'package:sakal/features/purchase/data/models/purchase_order_model.dart';
import 'package:sakal/features/purchase/domain/repositories/purchase_order_repository.dart';
import 'package:sakal/features/purchase/presentation/providers/purchase_order_providers.dart';
import 'package:sakal/features/purchase/presentation/screens/purchase_order_entry_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockPurchaseOrderRepository extends Mock implements PurchaseOrderRepository {}

class _FakeStringDynamicMap extends Fake implements Map<String, dynamic> {}
class _FakeStringDynamicMapList extends Fake implements List<Map<String, dynamic>> {}

Future<void> _pumpBriefly(WidgetTester tester, {int times = 5}) async {
  for (var i = 0; i < times; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The line-items grid renders as a mobile SakalLineItemCard (title
/// "N. <product>") below 600px, and a desktop table row above it — the
/// flutter_test default viewport (~800x600) is above 600 but below this
/// app's own 1024px desktop breakpoint elsewhere, so it lands on the
/// desktop branch by default. Tests asserting the mobile-only card title
/// text need to force a narrower viewport before pumping.
void _useMobileViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// SakalFieldCard renders its label as a raw RichText, not wrapped in
/// Text/Text.rich — find.text()/find.textContaining() don't reliably match
/// a bare RichText, so match directly against the TextSpan's own plain text.
Finder _findFieldLabel(String label) => find.byWidgetPredicate(
      (w) => w is RichText && w.maxLines == 1 && w.text.toPlainText().toUpperCase().contains(label.toUpperCase()),
    );

void main() {
  late MockPurchaseOrderRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
  });

  setUp(() {
    mockRepo = MockPurchaseOrderRepository();
    // Every test reaches _init(), which always fetches this fixed set of
    // reference data regardless of new-vs-edit mode.
    when(() => mockRepo.getProductsForPicker(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => []);
    when(() => mockRepo.getCommonMastersByType(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          typeKey: MasterTypeKey.unit,
        )).thenAnswer((_) async => [
          {'id': 'uom-001', 'description': 'Piece'},
        ]);
    when(() => mockRepo.getCommonMastersByType(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          typeKey: MasterTypeKey.department,
        )).thenAnswer((_) async => []);
    when(() => mockRepo.getCommonMastersByType(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          typeKey: MasterTypeKey.consumptionArea,
        )).thenAnswer((_) async => []);
    when(() => mockRepo.getCommonMastersByType(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          typeKey: MasterTypeKey.paymentTerms,
        )).thenAnswer((_) async => []);
    when(() => mockRepo.getTaxGroups(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => []);
    when(() => mockRepo.getAdditionalCharges(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => []);
    when(() => mockRepo.getTaxGroupMemberTaxIds(any())).thenAnswer((_) async => {});
    when(() => mockRepo.getTaxRatesByIds(
          taxIds: any(named: 'taxIds'),
          asOfDate: any(named: 'asOfDate'),
        )).thenAnswer((_) async => {});
    // The Buyer dropdown's initialValue defaults to session.userId ('user-001')
    // on a brand-new order — must be present in getUsers' own result or the
    // DropdownButtonFormField throws a "no matching item" assertion even on
    // the blank-form render.
    when(() => mockRepo.getUsers(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => [
          {'id': 'user-001', 'full_name': 'Test User'},
        ]);
  });

  // PurchaseOrderEntryScreen's own _init() also Future.waits on
  // accountsProvider/locationsProvider/baseCurrencyProvider/localCurrencyProvider
  // (core/providers/master_cache_providers.dart, plain FutureProviders) and
  // watches currenciesProvider directly in build() for the Currency dropdown
  // — all have to be overridden or the real provider chain runs and hits
  // DioClient/a real datasource.
  List<Override> overrides() => [
        purchaseOrderRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
        accountsProvider.overrideWith((ref) async => [
              {'id': 'sup-001', 'account_code': 'SUP-001', 'account_name': 'Test Supplier', 'account_nature': 'Supplier'},
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

  group('New (blank) purchase order', () {
    testWidgets('renders the blank form with all key fields, one auto-added blank line, and the charges/payment-terms sections',
        (tester) async {
      _useMobileViewport(tester); // asserts '1. New Line' — the mobile-only SakalLineItemCard title
      await pumpApp(tester, const PurchaseOrderEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      expect(find.text('New Purchase Order'), findsOneWidget);
      expect(find.text('Unsaved draft'), findsOneWidget);
      expect(_findFieldLabel('PO TYPE'), findsOneWidget);
      expect(_findFieldLabel('ORDER NO'), findsOneWidget);
      expect(_findFieldLabel('ORDER DATE'), findsOneWidget);
      expect(_findFieldLabel('SUPPLIER'), findsOneWidget);
      expect(_findFieldLabel('LOCATION'), findsOneWidget);
      expect(_findFieldLabel('CURRENCY'), findsOneWidget);

      // Additional Details is a collapsed ExpansionTile — only its own
      // title/subtitle are in the tree until expanded.
      expect(find.text('Additional Details'), findsOneWidget);

      // _init() auto-adds one blank line for a brand-new DIRECT order — the
      // "no lines" empty state is never actually reachable on this screen.
      expect(find.text('Line Items'), findsOneWidget);
      expect(find.text('No line items yet.'), findsNothing);
      expect(find.text('1. New Line'), findsOneWidget);
      expect(find.text('Add Item'), findsOneWidget);

      // Charges section is always present, even when empty.
      expect(find.text('Additional Charges'), findsOneWidget);
      expect(find.text('No additional charges (freight, loading, handling…).'), findsOneWidget);
      expect(find.text('Add Charge'), findsNothing); // no configured charge types in this fixture

      // Payment Terms section is always present, even when empty.
      expect(find.text('Payment Terms'), findsOneWidget);
      expect(find.text('No payment terms added.'), findsOneWidget);
      expect(find.text('Add Term'), findsNothing); // no configured payment-term masters in this fixture

      expect(find.text('Save Draft'), findsOneWidget);
      // A brand-new, never-saved order has no order number yet, so no copy
      // button, no print button, and no approve button.
      expect(find.byIcon(Icons.copy_outlined), findsNothing);
      expect(find.byIcon(Icons.print_outlined), findsNothing);
      expect(find.text('Approve'), findsNothing);
    });

    testWidgets('blocks save and shows a validation message when no supplier is selected', (tester) async {
      await pumpApp(tester, const PurchaseOrderEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      // _saveDraft() checks supplier first, before currency/location/lines.
      expect(find.text('Select a supplier.'), findsOneWidget);
      verifyNever(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            charges: any(named: 'charges'),
            paymentTerms: any(named: 'paymentTerms'),
            userId: any(named: 'userId'),
          ));
    });
  });

  group('Editing an existing DRAFT (resume flow, untracked line)', () {
    void stubExistingDraft() {
      when(() => mockRepo.getHeader(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            orderNo: any(named: 'orderNo'),
            orderDate: any(named: 'orderDate'),
          )).thenAnswer((_) async => const PurchaseOrderModel(
            id: 'po-1',
            clientId: 'client-001',
            companyId: 'company-001',
            locationId: 'loc-001',
            locationName: 'Main Warehouse',
            orderNo: 'PO-001',
            orderDate: '2026-07-01',
            poType: 'LOCAL',
            supplierId: 'sup-001',
            supplierCode: 'SUP-001',
            supplierName: 'Test Supplier',
            poCurrencyId: 'ccy-usd',
            poCurrencyCode: 'USD',
            rateToBase: 1,
            rateToLocal: 1,
            buyerId: 'user-001',
            buyerName: 'Test User',
            status: 'DRAFT',
            orderSubject: 'Test Subject',
            billTo: 'Bill To Address',
            shipTo: 'Ship To Address',
            remarks: 'Original remarks',
          ));
      when(() => mockRepo.getLines(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            orderNo: any(named: 'orderNo'),
            orderDate: any(named: 'orderDate'),
          )).thenAnswer((_) async => const [
            PurchaseOrderLineModel(
              id: 'line-1',
              serialNo: 1,
              productId: 'prod-001',
              productCode: 'WID-A',
              productName: 'Widget A',
              uomId: 'uom-001',
              uomLabel: 'Piece',
              uomConversionFactor: 1,
              qtyPack: 10,
              qtyLoose: 0,
              baseQty: 10,
              rate: 25,
              discountPercent: 0,
            ),
          ]);
      when(() => mockRepo.getCharges(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            orderNo: any(named: 'orderNo'),
            orderDate: any(named: 'orderDate'),
          )).thenAnswer((_) async => <PoChargeLineModel>[]);
      when(() => mockRepo.getPaymentTerms(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            orderNo: any(named: 'orderNo'),
            orderDate: any(named: 'orderDate'),
          )).thenAnswer((_) async => <PoPaymentTermModel>[]);
    }

    testWidgets('loads and displays every field from the saved header and line', (tester) async {
      stubExistingDraft();
      _useMobileViewport(tester); // asserts '1. [WID-A] Widget A' — the mobile-only SakalLineItemCard title

      await pumpApp(
        tester,
        const PurchaseOrderEntryScreen(editOrderNo: 'PO-001', editOrderDate: '2026-07-01'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      expect(find.text('Purchase Order · PO-001'), findsOneWidget);
      expect(find.text('Draft'), findsOneWidget);
      expect(find.text('[SUP-001] Test Supplier'), findsOneWidget); // Supplier autocomplete field text
      expect(find.text('Main Warehouse'), findsOneWidget); // Location dropdown
      expect(find.text('USD — US Dollar'), findsOneWidget); // Currency dropdown
      expect(find.text('Test User'), findsOneWidget); // Buyer dropdown

      // Line — untracked product, single line loaded from the saved draft.
      expect(find.text('1. [WID-A] Widget A'), findsOneWidget);
      expect(find.text('Piece'), findsOneWidget);
      expect(find.text('10.0'), findsOneWidget); // qtyPackCtrl set via l.qtyPack.toString()
      expect(find.text('25.0'), findsOneWidget); // rateCtrl set via l.rate.toString()

      // Additional Details is collapsed by default — Remarks isn't in the
      // tree until the ExpansionTile is expanded.
      expect(find.text('Original remarks'), findsNothing);
      await tester.tap(find.text('Additional Details'));
      await tester.pumpAndSettle();
      expect(find.text('Original remarks'), findsOneWidget);
      expect(find.text('Test Subject'), findsOneWidget);
      expect(find.text('Bill To Address'), findsOneWidget);
      expect(find.text('Ship To Address'), findsOneWidget);

      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.text('Approve'), findsNothing); // canApprove defaults false from the harness's empty menuProvider
      expect(find.byIcon(Icons.print_outlined), findsOneWidget); // a saved order is printable
      // _canCopy also requires canCopy (copyAllowed), which the harness's
      // empty menuProvider leaves false — same reasoning as Approve above.
      expect(find.byIcon(Icons.copy_outlined), findsNothing);
    });

    testWidgets('editing remarks and saving calls the repository with the updated payload', (tester) async {
      stubExistingDraft();
      when(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            charges: any(named: 'charges'),
            paymentTerms: any(named: 'paymentTerms'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'PO-001');
      when(() => mockRepo.cacheOrderLocally(
            effectiveOrderNo: any(named: 'effectiveOrderNo'),
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            charges: any(named: 'charges'),
            paymentTerms: any(named: 'paymentTerms'),
          )).thenAnswer((_) async {});

      await pumpApp(
        tester,
        const PurchaseOrderEntryScreen(editOrderNo: 'PO-001', editOrderDate: '2026-07-01'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      // Remarks lives inside the collapsed "Additional Details" section —
      // expand it before it can be found/edited.
      await tester.tap(find.text('Additional Details'));
      await tester.pumpAndSettle();

      await tester.enterText(find.text('Original remarks'), 'Updated remarks');
      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      final captured = verify(() => mockRepo.save(
            header: captureAny(named: 'header'),
            lines: captureAny(named: 'lines'),
            charges: any(named: 'charges'),
            paymentTerms: any(named: 'paymentTerms'),
            userId: any(named: 'userId'),
          )).captured;
      final header = captured[0] as Map<String, dynamic>;
      final lines = captured[1] as List<Map<String, dynamic>>;

      expect(header['order_no'], 'PO-001');
      expect(header['location_id'], 'loc-001');
      expect(header['supplier_id'], 'sup-001');
      expect(header['po_type'], 'LOCAL');
      expect(header['po_currency_id'], 'ccy-usd');
      expect(header['rate_to_base'], 1.0);
      expect(header['rate_to_local'], 1.0);
      expect(header['buyer_id'], 'user-001');
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
      expect(line['tax_group_id'], ''); // l.taxGroupId ?? ''
      expect(line['barcode'], ''); // l.matchedBarcode ?? ''

      expect(find.text('Draft saved — PO-001'), findsOneWidget);
    });
  });

  // Same pilot pattern as Stock Transfer Request / GRN, adapted for this
  // screen's own two pickers: Supplier (header) and Product (per line, on
  // the auto-added blank line every brand-new PO already has — see
  // _init()'s own `_addLine()` call and the "1. New Line" assertion in the
  // blank-form render test above). Like GRN, PO's `_searchField<T>` helper
  // filters an ALREADY-loaded list (`_suppliers`/`_products`) client-side on
  // every keystroke rather than calling the repository per keystroke — the
  // mock only needs its fixture data stubbed once.
  group('Supplier + Product autocomplete interaction (real search + select)', () {
    // Exact-match (never a bare substring) label lookup — SakalFieldCard
    // appends a child TextSpan(' *') for required fields, so a required
    // label's full toPlainText() is "LABEL *", not "LABEL". A plain
    // .contains() match would be ambiguous here too: "Rate" alone also
    // matches "Rate → Base (USD)"/"Rate → Local (FC)".
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
      await pumpApp(tester, const PurchaseOrderEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      final supplierField = fieldInCard('Supplier', () => find.byType(TextFormField));
      await tester.enterText(supplierField, 'Test');
      await tester.pumpAndSettle();

      expect(find.text('[SUP-001] Test Supplier'), findsOneWidget);

      await tester.tap(find.text('[SUP-001] Test Supplier'));
      // _searchField's SakalAutocomplete carries `key: ValueKey(initialText)`
      // (initialText == _supplierDisplay) — selecting changes _supplierDisplay,
      // forcing a remount.
      await tester.pumpAndSettle();

      // _onSupplierSelected sets _supplierId/_supplierDisplay — the field's
      // own displayed value is the simplest observable proof of selection.
      expect(find.text('[SUP-001] Test Supplier'), findsOneWidget);
    });

    testWidgets('typing into the Product field on the auto-added blank line shows the matching option, and selecting it updates the line title and rate',
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
              'purchase_tax_group_id': null,
              'last_purchase_cost': 25.5,
            },
          ]);
      when(() => mockRepo.getProductStockSnapshot(
            productId: any(named: 'productId'),
            locationId: any(named: 'locationId'),
          )).thenAnswer((_) async => {'current_stock': 0.0, 'reorder_level': 0.0});

      _useMobileViewport(tester); // asserts '1. New Line' / '1. [WID-A] Widget A' — the mobile-only SakalLineItemCard title
      await pumpApp(tester, const PurchaseOrderEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      // _init() auto-adds one blank line for a brand-new DIRECT order — no
      // "Add Item" tap needed, unlike GRN/Stock Transfer Request.
      expect(find.text('1. New Line'), findsOneWidget);

      final productField = fieldInCard('Product', () => find.byType(TextFormField));
      await tester.enterText(productField, 'Widget');
      await tester.pumpAndSettle();

      expect(find.text('[WID-A] Widget A'), findsOneWidget);

      await tester.tap(find.text('[WID-A] Widget A'));
      await tester.pumpAndSettle();

      // _onProductSelected sets row.productId/productDisplay (line title, a
      // plain Text — updates on rebuild, no remount needed) and
      // row.rateCtrl.text from last_purchase_cost (TextEditingController-
      // bound, not `initialValue`-driven, so it also updates live).
      expect(find.text('1. [WID-A] Widget A'), findsOneWidget);
      final rateField = fieldInCard('Rate', () => find.byType(TextFormField));
      expect(tester.widget<TextFormField>(rateField).controller!.text, '25.5');
    });
  });
}
