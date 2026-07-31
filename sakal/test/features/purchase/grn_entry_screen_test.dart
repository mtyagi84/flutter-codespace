import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/config/master_type_keys.dart';
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
      (w) => w is RichText && w.text.toPlainText().toUpperCase().contains(label.toUpperCase()),
    );

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

      expect(find.text('New Goods Receipt'), findsOneWidget);
      expect(find.text('Unsaved draft'), findsOneWidget);
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

      await pumpApp(
        tester,
        const GrnEntryScreen(editGrnNo: 'GRN-001', editGrnDate: '2026-07-01'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      expect(find.text('Goods Receipt · GRN-001'), findsOneWidget);
      expect(find.text('Draft'), findsOneWidget);
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
}
