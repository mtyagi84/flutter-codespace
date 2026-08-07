import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/config/master_type_keys.dart';
import 'package:sakal/core/layout/screen_header.dart';
import 'package:sakal/core/providers/master_cache_providers.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/core/widgets/sakal_field_card.dart';
import 'package:sakal/features/purchase/data/models/grn_charge_line_model.dart';
import 'package:sakal/features/purchase/data/models/grn_line_model.dart';
import 'package:sakal/features/purchase/data/models/grn_model.dart';
import 'package:sakal/features/purchase/domain/repositories/grn_repository.dart';
import 'package:sakal/features/purchase/presentation/providers/grn_providers.dart';
import 'package:sakal/features/purchase/presentation/screens/grn_entry_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockGrnRepository extends Mock implements GrnRepository {}

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

/// Forces a viewport narrower than the app's 600px mobile breakpoint —
/// flutter_test's own default (~800x600) falls on the DESKTOP side of that
/// threshold, so the Lines section's isMobile branch (SakalLineItemCard,
/// "N. Title" text) would otherwise never render; these tests were written
/// against that mobile-card shape.
void _useMobileViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  late MockGrnRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
  });

  setUp(() {
    mockRepo = MockGrnRepository();
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
  });

  // GRN's own _init() also Future.waits on accountsProvider/locationsProvider/
  // baseCurrencyProvider/localCurrencyProvider (core/providers/master_cache_providers.dart,
  // plain FutureProviders) and watches currenciesProvider directly in build()
  // for the Currency dropdown — all have to be overridden or the real
  // provider chain runs and hits DioClient/a real datasource.
  List<Override> overrides() => [
        grnRepositoryProvider.overrideWithValue(mockRepo),
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

  group('New (blank) GRN', () {
    testWidgets('renders the blank form with all key fields, empty lines, and the charges section', (tester) async {
      await pumpApp(tester, const GrnEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      final header = _readHeader(tester, find.byType(GrnEntryScreen));
      expect(header?.title, 'New Goods Receipt');
      expect(header?.subtitle, 'Unsaved draft');
      expect(_findFieldLabel('RECEIPT MODE'), findsOneWidget);
      expect(_findFieldLabel('GRN NO'), findsOneWidget);
      expect(_findFieldLabel('GRN DATE'), findsOneWidget);
      expect(_findFieldLabel('LOCATION'), findsOneWidget);
      expect(_findFieldLabel('CURRENCY'), findsOneWidget);
      expect(_findFieldLabel('SUPPLIER DELIVERY NO'), findsOneWidget);
      expect(_findFieldLabel('SUPPLIER DELIVERY DATE'), findsOneWidget);

      // Additional Details is a collapsed ExpansionTile — only its own
      // title/subtitle are in the tree until expanded (Bill To/Ship
      // To/Remarks children are not built while collapsed).
      expect(find.text('Additional Details'), findsOneWidget);

      expect(find.text('Line Items'), findsOneWidget);
      expect(find.text('No line items yet.'), findsOneWidget);
      expect(find.text('Add Item'), findsOneWidget);

      // Charges section is always present, even when empty.
      expect(find.text('Additional Charges'), findsOneWidget);
      expect(find.text('No additional charges (freight, loading, handling…).'), findsOneWidget);
      expect(find.text('Add Charge'), findsNothing); // no configured charge types in this fixture

      expect(find.text('Save Draft'), findsOneWidget);
      // A brand-new, never-saved GRN has no GRN number yet, so no print
      // button and no approve button (approve requires _grnNo != null).
      expect(find.byIcon(Icons.print_outlined), findsNothing);
      expect(find.text('Approve'), findsNothing);
    });

    testWidgets('blocks save and shows a validation message when no supplier is selected', (tester) async {
      await pumpApp(tester, const GrnEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      // _saveDraft() checks supplier first, before currency/location/lines.
      expect(find.text('Select a supplier.'), findsOneWidget);
      verifyNever(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            charges: any(named: 'charges'),
            userId: any(named: 'userId'),
          ));
    });
  });

  group('Editing an existing DRAFT (resume flow, DIRECT mode, untracked line)', () {
    void stubExistingDraft() {
      when(() => mockRepo.getHeader(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            grnNo: any(named: 'grnNo'),
            grnDate: any(named: 'grnDate'),
          )).thenAnswer((_) async => const GrnModel(
            id: 'grn-1',
            clientId: 'client-001',
            companyId: 'company-001',
            locationId: 'loc-001',
            locationName: 'Main Warehouse',
            grnNo: 'GRN-001',
            grnDate: '2026-07-01',
            supplierId: 'sup-001',
            supplierCode: 'SUP-001',
            supplierName: 'Test Supplier',
            receiptMode: 'DIRECT',
            supplierDeliveryNo: 'DN-100',
            supplierDeliveryDate: '2026-06-30',
            grnCurrencyId: 'ccy-usd',
            grnCurrencyCode: 'USD',
            rateToBase: 1,
            rateToLocal: 1,
            billTo: 'Bill To Address',
            shipTo: 'Ship To Address',
            remarks: 'Original remarks',
            status: 'DRAFT',
          ));
      when(() => mockRepo.getLines(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            grnNo: any(named: 'grnNo'),
            grnDate: any(named: 'grnDate'),
          )).thenAnswer((_) async => const [
            GrnLineModel(
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
              batches: [],
              serials: [],
            ),
          ]);
      when(() => mockRepo.getCharges(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            grnNo: any(named: 'grnNo'),
            grnDate: any(named: 'grnDate'),
          )).thenAnswer((_) async => <GrnChargeLineModel>[]);
    }

    testWidgets('loads and displays every field from the saved header and line', (tester) async {
      stubExistingDraft();
      _useMobileViewport(tester);

      await pumpApp(
        tester,
        const GrnEntryScreen(editGrnNo: 'GRN-001', editGrnDate: '2026-07-01'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      final header = _readHeader(tester, find.byType(GrnEntryScreen));
      expect(header?.title, 'Goods Receipt · GRN-001');
      // A still-DRAFT (unlocked) resumed GRN shows 'Draft' as the
      // subtitle, not badgeText — badgeText only populates once locked
      // (status != DRAFT), per buildScreenHeader()'s own contract.
      expect(header?.subtitle, 'Draft');
      expect(find.text('[SUP-001] Test Supplier'), findsOneWidget); // Supplier autocomplete field text
      expect(find.text('Main Warehouse'), findsOneWidget); // Location dropdown
      expect(find.text('USD — US Dollar'), findsOneWidget); // Currency dropdown
      expect(find.text('DN-100'), findsOneWidget); // Supplier Delivery No
      expect(find.text('30 Jun 2026'), findsOneWidget); // Supplier Delivery Date

      // Line — trackingType NONE, so no batch/serial editor renders.
      expect(find.text('1. [WID-A] Widget A'), findsOneWidget);
      expect(find.text('Piece'), findsOneWidget);
      expect(find.text('10.0'), findsOneWidget); // qtyPackCtrl set via l.qtyPack.toString()
      expect(find.text('25.0'), findsOneWidget); // rateCtrl set via l.rate.toString()
      expect(find.text('Final: 250.00'), findsOneWidget); // _amountTag footer, toStringAsFixed(2)

      // Additional Details is collapsed by default — Remarks isn't in the
      // tree until the ExpansionTile is expanded.
      expect(find.text('Original remarks'), findsNothing);
      await tester.tap(find.text('Additional Details'));
      await tester.pumpAndSettle();
      expect(find.text('Original remarks'), findsOneWidget);
      expect(find.text('Bill To Address'), findsOneWidget);
      expect(find.text('Ship To Address'), findsOneWidget);

      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.text('Approve'), findsNothing); // canApprove defaults false from the harness's empty menuProvider
      expect(find.byIcon(Icons.print_outlined), findsOneWidget); // a saved GRN is printable
    });

    testWidgets('editing remarks and saving calls the repository with the updated payload', (tester) async {
      stubExistingDraft();
      when(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            charges: any(named: 'charges'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'GRN-001');
      when(() => mockRepo.cacheGrnLocally(
            effectiveGrnNo: any(named: 'effectiveGrnNo'),
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            charges: any(named: 'charges'),
          )).thenAnswer((_) async {});

      await pumpApp(
        tester,
        const GrnEntryScreen(editGrnNo: 'GRN-001', editGrnDate: '2026-07-01'),
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
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            charges: any(named: 'charges'),
            userId: any(named: 'userId'),
          )).captured;
      final header = captured[0] as Map<String, dynamic>;
      final lines = captured[1] as List<Map<String, dynamic>>;

      expect(header['grn_no'], 'GRN-001');
      expect(header['location_id'], 'loc-001');
      expect(header['supplier_id'], 'sup-001');
      expect(header['receipt_mode'], 'DIRECT');
      expect(header['grn_currency_id'], 'ccy-usd');
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
      expect(line['tax_group_id'], ''); // l.taxGroupId ?? ''
      expect(line['barcode'], ''); // l.matchedBarcode ?? ''

      expect(find.text('Draft saved — GRN-001'), findsOneWidget);
    });
  });

  // Every prior GRN test batch (Phase 5) deliberately excluded driving
  // SakalAutocomplete through real user interaction (type -> see filtered
  // options -> tap one) — this group drives GRN's own two pickers, Supplier
  // (header) and Product (per line), the same way the Stock Transfer
  // Request pilot proved out. Unlike that pilot's async
  // getProductsForPicker(search:) call per keystroke, GRN's own
  // `_searchField<T>` helper (built on SakalAutocomplete, see the widget's
  // own doc-comment in sakal_autocomplete.dart) filters an ALREADY-loaded
  // list (`_suppliers`/`_products`, both fetched once in _init()) purely
  // client-side on every keystroke — so the mock only needs to return its
  // fixture data once, not per search term, and pumpAndSettle() after
  // typing is still the right tool (it lets RawAutocomplete's own
  // OverlayEntry build/render, even though there's no real async gap here).
  group('Supplier + Product autocomplete interaction (real search + select)', () {
    // Stricter than a plain "contains" label match: SakalFieldCard appends
    // a child TextSpan(' *') for required fields (see sakal_field_card.dart),
    // so a required label's full toPlainText() is "LABEL *", not "LABEL".
    // Matching either form exactly (never a bare substring) avoids the real
    // ambiguity on this screen — e.g. a "Supplier" query would otherwise
    // also match "Supplier Delivery No"/"Supplier Delivery Date" via
    // .contains(), and "Rate" would also match "Rate → Base (USD)"/"Rate →
    // Local (FC)".
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
      await pumpApp(tester, const GrnEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      final supplierField = fieldInCard('Supplier', () => find.byType(TextFormField));
      await tester.enterText(supplierField, 'Test');
      // _searchField's own optionsBuilder filters the already-loaded
      // _suppliers list (from accountsProvider, overridden above to one
      // Supplier-natured account) synchronously — pumpAndSettle just lets
      // RawAutocomplete's OverlayEntry render the filtered options.
      await tester.pumpAndSettle();

      expect(find.text('[SUP-001] Test Supplier'), findsOneWidget);

      await tester.tap(find.text('[SUP-001] Test Supplier'));
      // _searchField's SakalAutocomplete carries `key: ValueKey(initialText)`
      // (initialText == _supplierDisplay) — selecting changes _supplierDisplay,
      // forcing a remount; pumpAndSettle lets that finish.
      await tester.pumpAndSettle();

      // _onSupplierSelected sets _supplierId/_supplierDisplay — the field's
      // own displayed value is the simplest observable proof the selection
      // landed, without needing to save and inspect a payload.
      expect(find.text('[SUP-001] Test Supplier'), findsOneWidget);
    });

    testWidgets('typing into the Product field on a freshly added line shows the matching option, and selecting it updates the line title and rate',
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
              'tracking_type': 'NONE',
              'purchase_tax_group_id': null,
              'allowed_cost_variance': 0,
              'last_purchase_cost': 25.5,
            },
          ]);
      when(() => mockRepo.getProductLastCostPrice(
            productId: any(named: 'productId'),
            locationId: any(named: 'locationId'),
          )).thenAnswer((_) async => null);

      _useMobileViewport(tester);
      await pumpApp(tester, const GrnEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add Item'));
      await tester.pumpAndSettle();

      // Before any product is picked, the fresh line's own title falls back
      // to 'New Line' (`'${idx+1}. ${row.productDisplay.isEmpty ? 'New Line' : row.productDisplay}'`).
      expect(find.text('1. New Line'), findsOneWidget);

      final productField = fieldInCard('Product', () => find.byType(TextFormField));
      await tester.enterText(productField, 'Widget');
      await tester.pumpAndSettle();

      expect(find.text('[WID-A] Widget A'), findsOneWidget);

      await tester.tap(find.text('[WID-A] Widget A'));
      await tester.pumpAndSettle();

      // _onProductSelected sets row.productId/productDisplay (the
      // SakalLineItemCard title is a plain Text, not FormField-family, so it
      // updates on every rebuild with no remount needed) and
      // row.rateCtrl.text from last_purchase_cost — the Rate field is
      // TextEditingController-bound (not `initialValue`-driven like a
      // DropdownButtonFormField), so it also updates live with no key/remount
      // gotcha. Both are directly observable without saving and inspecting
      // a payload.
      expect(find.text('1. [WID-A] Widget A'), findsOneWidget);
      final rateField = fieldInCard('Rate', () => find.byType(TextFormField));
      expect(tester.widget<TextFormField>(rateField).controller!.text, '25.5');
    });
  });

  // Every prior GRN test batch (Phase 5, then the autocomplete pilot above)
  // deliberately exercised DIRECT mode only. This group closes that gap for
  // AGAINST_PO — the multi-step wizard chained from _onReceiptModeChanged:
  // _startAgainstPoWizard (pick a supplier that has open POs) ->
  // _pickCurrencyThenPos (resolve currency, then pick PO(s)) ->
  // _consolidatePos (fetch each PO's pending lines + charge lines and add
  // them to the GRN's own _lines/_charges). Confirmed by reading the full
  // screen file directly, not assumed:
  //   - getSuppliersWithOpenPos(clientId, companyId)
  //   - getOpenPurchaseOrdersForSupplier(clientId, companyId, supplierId)
  //   - getPendingPoLines(clientId, companyId, orderNo, orderDate, excludeGrnNo)
  //   - getPoChargeLinesForOrder(clientId, companyId, orderNo, orderDate)
  // A PO-derived line is stamped row.isFromPo = (sourcePoOrderNo != null),
  // which locks Product/UOM/Rate/Discount/Tax Group and renders a
  // 'PO: <orderNo>' subtitle on the SakalLineItemCard (_buildLineCard) —
  // that subtitle is this group's strongest proof of consolidation, since
  // it can't come from any other code path.
  group('Against-PO consolidation (real wizard flow: pick supplier -> pick PO -> lines land in the grid)', () {
    // Same exact-match helper as the Supplier + Product autocomplete group
    // above, duplicated locally per this file's own established convention
    // (each group defines its own copy rather than sharing one across groups).
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

    void stubAgainstPoWizard() {
      when(() => mockRepo.getSuppliersWithOpenPos(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
          )).thenAnswer((_) async => [
            {'id': 'sup-001', 'account_code': 'SUP-001', 'account_name': 'Test Supplier'},
          ]);
      when(() => mockRepo.getOpenPurchaseOrdersForSupplier(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            supplierId: any(named: 'supplierId'),
          )).thenAnswer((_) async => [
            {
              'order_no': 'PO-2001',
              'order_date': '2026-07-15',
              'po_currency_id': 'ccy-usd',
              'currency': {'currency_id': 'USD'},
              'rate_to_base': 1.0,
              'rate_to_local': 1.0,
              'bill_to': '',
              'ship_to': '',
            },
          ]);
      when(() => mockRepo.getPendingPoLines(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            orderNo: any(named: 'orderNo'),
            orderDate: any(named: 'orderDate'),
            excludeGrnNo: any(named: 'excludeGrnNo'),
          )).thenAnswer((_) async => [
            {
              'product_id': 'prod-001',
              'product': {
                'product_code': 'WID-A',
                'product_name': 'Widget A',
                'tracking_type': 'NONE',
                'allowed_cost_variance': 0,
              },
              'pending_qty': 10.0,
              'uom_conversion_factor': 1.0,
              'uom_id': 'uom-001',
              'tax_group_id': null,
              'department_id': null,
              'consumption_area_id': null,
              'serial_no': 1,
              'item_description': '',
              'rate': 25.0,
              'discount_percent': 0,
            },
          ]);
      when(() => mockRepo.getPoChargeLinesForOrder(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            orderNo: any(named: 'orderNo'),
            orderDate: any(named: 'orderDate'),
          )).thenAnswer((_) async => []);
      when(() => mockRepo.getProductLastCostPrice(
            productId: any(named: 'productId'),
            locationId: any(named: 'locationId'),
          )).thenAnswer((_) async => null);
    }

    // Drives the full wizard: Receipt Mode -> Against PO, pick the one
    // stubbed supplier, pick the one stubbed PO, confirm — mirroring
    // _startAgainstPoWizard -> _pickCurrencyThenPos -> _consolidatePos.
    // _consolidatePos shows a transient 'Added N line(s)…' SnackBar at the
    // end (same _showSnack helper Save Draft uses), so — per this file's own
    // rule about never pumpAndSettle() right after an action that shows a
    // SnackBar — the final step uses _pumpBriefly, not pumpAndSettle.
    Future<void> runAgainstPoWizard(WidgetTester tester) async {
      final receiptModeDropdown = fieldInCard('Receipt Mode', () => find.byType(DropdownButtonFormField<String>));
      await tester.tap(receiptModeDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Against PO').last);
      await tester.pumpAndSettle();

      // _startAgainstPoWizard's supplier picker dialog.
      expect(find.text('Select Supplier'), findsOneWidget);
      await tester.tap(find.text('[SUP-001] Test Supplier'));
      await tester.pumpAndSettle();

      // _pickCurrencyThenPos's PO picker dialog — one open PO with one
      // currency, so currency auto-resolves with no separate dialog of its
      // own (byCurrency.length <= 1 branch).
      expect(find.text('Select Purchase Order(s)'), findsOneWidget);
      await tester.tap(find.text('PO-2001'));
      await tester.pump();
      await tester.tap(find.text('Add Selected'));
      await _pumpBriefly(tester, times: 10);
    }

    testWidgets(
        'switching to Against PO, picking a supplier then a PO consolidates its pending line into the grid',
        (tester) async {
      stubAgainstPoWizard();
      _useMobileViewport(tester);

      await pumpApp(tester, const GrnEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      await runAgainstPoWizard(tester);

      // Supplier locks into the read-only display field once AGAINST_PO is
      // active (_receiptMode == 'AGAINST_PO' branch of supplierField).
      expect(find.text('[SUP-001] Test Supplier'), findsOneWidget);

      // Purchase Orders consolidation section shows the picked PO as a chip.
      expect(find.text('PO-2001'), findsOneWidget);

      // The PO's pending line landed as its own line card — title format
      // matches DIRECT mode's own ('idx. productDisplay'), plus the
      // 'PO: PO-2001' subtitle that only a PO-derived row ever renders.
      expect(find.text('1. [WID-A] Widget A'), findsOneWidget);
      expect(find.text('PO: PO-2001'), findsOneWidget);
      expect(find.text('10.0000'), findsOneWidget); // qtyPackCtrl: (pending_qty / convFactor).toStringAsFixed(4)
      expect(find.text('25.0'), findsOneWidget); // rateCtrl: (pl['rate'] as num).toString()
      expect(find.text('Final: 250.00'), findsOneWidget); // baseQty 10 * rate 25, no tax group configured
    });

    testWidgets('saving after Against-PO consolidation sends receipt_mode and PO traceability in the payload', (tester) async {
      stubAgainstPoWizard();
      when(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            charges: any(named: 'charges'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'GRN-002');
      when(() => mockRepo.cacheGrnLocally(
            effectiveGrnNo: any(named: 'effectiveGrnNo'),
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            charges: any(named: 'charges'),
          )).thenAnswer((_) async {});

      _useMobileViewport(tester);
      await pumpApp(tester, const GrnEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      await runAgainstPoWizard(tester);

      // The wizard's own consolidation step already queued an 'Added N
      // line(s)…' SnackBar via the same ScaffoldMessenger — by default it
      // queues a second SnackBar behind the first rather than replacing it,
      // so 'Draft saved — GRN-002' would otherwise sit unseen behind it for
      // that SnackBar's full ~4s duration. Clear the queue first so Save
      // Draft's own SnackBar shows immediately.
      ScaffoldMessenger.of(tester.element(find.byType(GrnEntryScreen))).clearSnackBars();
      await tester.pump();

      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester, times: 10);

      final captured = verify(() => mockRepo.save(
            header: captureAny(named: 'header'),
            lines: captureAny(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            charges: any(named: 'charges'),
            userId: any(named: 'userId'),
          )).captured;
      final header = captured[0] as Map<String, dynamic>;
      final lines = captured[1] as List<Map<String, dynamic>>;

      expect(header['receipt_mode'], 'AGAINST_PO');
      expect(header['supplier_id'], 'sup-001');
      expect(header['grn_currency_id'], 'ccy-usd');

      expect(lines, hasLength(1));
      final line = lines.first;
      expect(line['product_id'], 'prod-001');
      expect(line['source_po_order_no'], 'PO-2001');
      expect(line['source_po_order_date'], '2026-07-15');
      expect(line['source_po_line_serial'], 1);
      expect(line['qty_pack'], 10.0);
      expect(line['rate'], 25.0);

      expect(find.text('Draft saved — GRN-002'), findsOneWidget);
    });
  });
}
