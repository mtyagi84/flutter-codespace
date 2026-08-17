import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/layout/screen_header.dart';
import 'package:sakal/core/providers/master_cache_providers.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/core/widgets/sakal_field_card.dart';
import 'package:sakal/features/purchase/data/models/purchase_return_model.dart';
import 'package:sakal/features/purchase/domain/repositories/purchase_return_repository.dart';
import 'package:sakal/features/purchase/presentation/providers/purchase_return_providers.dart';
import 'package:sakal/features/purchase/presentation/screens/purchase_return_entry_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockPurchaseReturnRepository extends Mock implements PurchaseReturnRepository {}

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
/// for rendered text — this is the actual observable contract the screen
/// provides now.
ScreenHeaderInfo? _readHeader(WidgetTester tester, Finder screenFinder) =>
    ProviderScope.containerOf(tester.element(screenFinder)).read(screenHeaderProvider);

void main() {
  late MockPurchaseReturnRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
  });

  setUp(() {
    mockRepo = MockPurchaseReturnRepository();
    // _init() also calls getUsers() unconditionally to resolve signature
    // names — an unstubbed Mock call throws, silently caught by _init()'s
    // own try/catch, which broke every resume-flow assertion depending on
    // post-load state (e.g. the header title).
    when(() => mockRepo.getUsers(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => []);
    // Every test reaches _init(), which always calls
    // getSuppliersWithApprovedGrns() and getCommonMastersByType() first,
    // regardless of new-vs-edit mode.
    when(() => mockRepo.getSuppliersWithApprovedGrns(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => []);
    when(() => mockRepo.getCommonMastersByType(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          typeKey: any(named: 'typeKey'),
        )).thenAnswer((_) async => []);
  });

  List<Override> overrides() => [
        purchaseReturnRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
        // currenciesProvider hits DioClient directly when unmocked — override
        // its Future straight to a fixed list so the header card's currency
        // row resolves without a real network/platform-channel dependency.
        currenciesProvider.overrideWith((ref) async => [
              {'id': 'ccy-001', 'currency_id': 'USD', 'currency_name': 'US Dollar', 'rate_decimal_places': 2},
            ]),
      ];

  group('New (blank) return', () {
    testWidgets('renders the blank form with all key fields and no lines yet', (tester) async {
      await pumpApp(tester, const PurchaseReturnEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      final header = _readHeader(tester, find.byType(PurchaseReturnEntryScreen));
      expect(header?.title, 'New Purchase Return');
      expect(header?.subtitle, 'Unsaved draft');

      expect(_findFieldLabel('SUPPLIER *'), findsOneWidget);
      expect(_findFieldLabel('RETURN NO'), findsOneWidget);
      expect(_findFieldLabel('RETURN DATE'), findsOneWidget);
      expect(_findFieldLabel('CURRENCY (INHERITED FROM GRN)'), findsOneWidget);
      expect(_findFieldLabel('REASON'), findsOneWidget);

      // GRN picker card — this screen consolidates from GRN lines, there is
      // no free-text "Add Line" affordance anywhere.
      expect(find.text('Approved GRNs'), findsOneWidget);
      expect(find.text('Select a supplier to see their approved GRNs (billed or not).'), findsOneWidget);

      expect(find.text('Return Lines'), findsOneWidget);
      expect(find.text('No lines yet — pick a GRN above.'), findsOneWidget);

      // No saved charges and no GRN picked yet -> the Charges card renders
      // nothing at all (SizedBox.shrink()).
      expect(find.text('Additional Charges'), findsNothing);

      expect(_findFieldLabel('TAXABLE AMOUNT'), findsOneWidget);
      expect(_findFieldLabel('VAT / TAX AMOUNT'), findsOneWidget);
      expect(_findFieldLabel('RETURN TOTAL'), findsOneWidget);
      expect(_findFieldLabel('REMARKS'), findsOneWidget);

      expect(find.text('Save Draft'), findsOneWidget);
      // A brand-new, never-saved return has no return number yet, so no
      // print button and no approve button (approve requires !_isNew).
      expect(header?.actions.length, 1); // Save Draft now shows in the desktop TopBar
      expect(find.text('Approve'), findsNothing);
    });

    testWidgets('blocks save and shows a validation message when no supplier is selected', (tester) async {
      await pumpApp(tester, const PurchaseReturnEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

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

  group('Editing an existing DRAFT (resume flow — consolidated from a GRN, untracked line)', () {
    void stubExistingDraft() {
      when(() => mockRepo.getHeader(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            returnNo: any(named: 'returnNo'),
            returnDate: any(named: 'returnDate'),
          )).thenAnswer((_) async => const PurchaseReturnModel(
            id: 'ret-1',
            clientId: 'client-001',
            companyId: 'company-001',
            locationId: 'loc-001',
            returnNo: 'PRET-001',
            returnDate: '2026-07-10',
            supplierId: 'sup-001',
            supplierCode: 'SUP01',
            supplierName: 'Supplier One',
            returnCurrencyId: 'ccy-001',
            returnCurrencyCode: 'USD',
            rateToBase: 1,
            rateToLocal: 1,
            taxableAmount: 500,
            taxAmount: 80,
            returnTotal: 580,
            reason: 'Damaged goods',
            remarks: 'Return remarks',
            status: 'DRAFT',
          ));
      when(() => mockRepo.getGrnsForSupplier(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            supplierId: any(named: 'supplierId'),
          )).thenAnswer((_) async => [
            {
              'grn_no': 'GRN-001',
              'grn_date': '2026-06-30',
              'grn_currency_id': 'ccy-001',
              'currency': {'currency_id': 'USD'},
              'billed_invoice_no': null, // not yet billed -> "Not Billed" badge
            },
          ]);
      when(() => mockRepo.getFullyReturnedGrnKeys(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
          )).thenAnswer((_) async => <String>{});
      when(() => mockRepo.getReturnLines(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            returnNo: any(named: 'returnNo'),
            returnDate: any(named: 'returnDate'),
          )).thenAnswer((_) async => [
            {
              'source_grn_no': 'GRN-001',
              'source_grn_date': '2026-06-30',
              'source_grn_line_serial': 1,
              'product_id': 'prod-001',
              'serial_no': 1,
              'qty_pack': 8,
              'qty_loose': 0,
              'base_qty': 8,
            },
          ]);
      when(() => mockRepo.getGrnLines(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            grnNo: any(named: 'grnNo'),
            grnDate: any(named: 'grnDate'),
          )).thenAnswer((_) async => [
            {
              'serial_no': 1,
              'product_id': 'prod-001',
              'product': {'product_code': 'WID-A', 'product_name': 'Widget A', 'tracking_type': 'NONE'},
              'uom_id': 'uom-001',
              'uom': {'description': 'Piece'},
              'uom_conversion_factor': 1,
              'base_qty': 10, // GRN's original received qty
              'rate': 25,
              'tax_group_id': 'taxgrp-001',
              'tax_amount': 40, // GRN's own estimated (deferred) tax
              'barcode': null,
              'source_po_order_no': null,
            },
          ]);
      when(() => mockRepo.getReturnCharges(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            returnNo: any(named: 'returnNo'),
            returnDate: any(named: 'returnDate'),
          )).thenAnswer((_) async => []);
    }

    testWidgets('loads and displays every field from the saved header, GRN, and untracked line', (tester) async {
      stubExistingDraft();

      await pumpApp(
        tester,
        const PurchaseReturnEntryScreen(editReturnNo: 'PRET-001', editReturnDate: '2026-07-10'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      final header = _readHeader(tester, find.byType(PurchaseReturnEntryScreen));
      expect(header?.title, 'Purchase Return · PRET-001');
      expect(header?.subtitle, 'Draft');
      expect(find.textContaining('Supplier One'), findsWidgets); // '[SUP01] Supplier One'
      expect(find.text('10 Jul 2026'), findsOneWidget); // Return Date
      expect(find.text('USD — US Dollar'), findsOneWidget); // Currency, resolved from currenciesProvider
      expect(find.text('Damaged goods'), findsOneWidget); // Reason dropdown's selected value
      expect(find.text('Return remarks'), findsOneWidget);

      // header.taxableAmount/taxAmount are doubles assigned via `.toString()`
      // (not toStringAsFixed) in _init() — 500 -> "500.0".
      expect(find.text('500.0'), findsOneWidget);
      expect(find.text('80.0'), findsOneWidget);

      // GRN picker — pre-checked (present in _selectedGrnKeys from resume),
      // shown "Not Billed" since billed_invoice_no is null.
      expect(find.text('GRN-001'), findsOneWidget);
      expect(find.text('Not Billed'), findsOneWidget);

      // Return line, re-enriched from the GRN's own line data.
      expect(find.textContaining('Widget A'), findsWidgets);
      expect(find.text('GRN GRN-001 · Received 10.00 Piece'), findsOneWidget); // SakalLineItemCard subtitle
      expect(find.text('Piece'), findsOneWidget);
      expect(find.text('8.00'), findsOneWidget); // Return Qty Pack — initialQtyPack from saved qty_pack
      expect(find.text('0.00'), findsOneWidget); // Return Qty Loose
      expect(find.text('25.00'), findsOneWidget); // Rate, AppNumberFormat.amount(25, ...)
      expect(find.text('232.00'), findsOneWidget); // Amount = grossAmount(200) + suggestedTaxAmount(32)
      expect(find.text('Taxable 200.00 · VAT 32.00 · Total 232.00'), findsOneWidget);

      // No batch/serial editor for an untracked (tracking_type: NONE) line.
      expect(find.text('Select Batches to Return'), findsNothing);
      expect(find.text('Select Serial Numbers to Return'), findsNothing);

      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.text('Approve'), findsNothing); // canApprove defaults false from the harness's empty menuProvider
      expect(header?.actions.length, 2); // Save Draft + Print now show in the desktop TopBar
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
          )).thenAnswer((_) async => 'PRET-001');
      when(() => mockRepo.cacheReturnLocally(
            effectiveReturnNo: any(named: 'effectiveReturnNo'),
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            charges: any(named: 'charges'),
          )).thenAnswer((_) async {});

      await pumpApp(
        tester,
        const PurchaseReturnEntryScreen(editReturnNo: 'PRET-001', editReturnDate: '2026-07-10'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.text('Return remarks'), 'Updated remarks');
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

      expect(header['client_id'], 'client-001');
      expect(header['company_id'], 'company-001');
      expect(header['location_id'], 'loc-001');
      expect(header['return_no'], 'PRET-001');
      expect(header['return_date'], '2026-07-10');
      expect(header['supplier_id'], 'sup-001');
      expect(header['return_currency_id'], 'ccy-001');
      expect(header['rate_to_base'], 1.0);
      expect(header['rate_to_local'], 1.0);
      expect(header['taxable_amount'], 500.0);
      expect(header['tax_amount'], 80.0);
      expect(header['return_total'], 580.0);
      expect(header['reason'], 'Damaged goods');
      expect(header['remarks'], 'Updated remarks');

      expect(lines, hasLength(1));
      final line = lines.first;
      expect(line['serial_no'], 1);
      expect(line['source_grn_no'], 'GRN-001');
      expect(line['source_grn_date'], '2026-06-30');
      expect(line['source_grn_line_serial'], 1);
      expect(line['product_id'], 'prod-001');
      expect(line['uom_id'], 'uom-001');
      expect(line['uom_conversion_factor'], 1.0);
      expect(line['qty_pack'], 8.0);
      expect(line['qty_loose'], 0.0);
      expect(line['base_qty'], 8.0); // returnQty
      expect(line['rate'], 25.0);
      expect(line['tax_group_id'], 'taxgrp-001');
      expect(line['gross_amount'], 200.0);
      expect(line['tax_amount'], 32.0); // suggestedTaxAmount = 40 * (8/10)
      expect(line['final_amount'], 232.0);
      expect(line['barcode'], '');

      expect(find.text('Purchase Return PRET-001 saved.'), findsOneWidget);
    });
  });

  // Same shape as Purchase Invoice — this screen is GRN-consolidation-only
  // (no free product-line SakalAutocomplete anywhere; lines only ever come
  // from ticking a GRN's checkbox in _buildGrnPickerCard), so this group
  // drives only the header's own Supplier picker, built the same way
  // Purchase Invoice's is: a SakalAutocomplete built directly inline
  // (`_buildHeaderCard`'s own `supplierField`), filtering an already-loaded
  // `_suppliers` list (fetched once in _init() via
  // getSuppliersWithApprovedGrns) client-side on every keystroke.
  group('Supplier autocomplete interaction (real search + select)', () {
    // Exact-match (never a bare substring) label lookup — SakalFieldCard
    // appends a child TextSpan(' *') for required fields, so a required
    // label's full toPlainText() is "LABEL *", not "LABEL". Matching either
    // form exactly avoids relying on this screen's own "Supplier" label
    // happening to be unambiguous today.
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

    testWidgets(
        'typing into the Supplier field shows the matching option, and selecting it loads that supplier\'s approved GRNs',
        (tester) async {
      when(() => mockRepo.getSuppliersWithApprovedGrns(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
          )).thenAnswer((_) async => [
            {'id': 'sup-001', 'account_code': 'SUP-001', 'account_name': 'Test Supplier'},
          ]);
      when(() => mockRepo.getGrnsForSupplier(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            supplierId: any(named: 'supplierId'),
          )).thenAnswer((_) async => [
            {
              'grn_no': 'GRN-001',
              'grn_date': '2026-06-30',
              'grn_currency_id': 'ccy-001',
              'currency': {'currency_id': 'USD'},
              'billed_invoice_no': null,
            },
          ]);
      when(() => mockRepo.getFullyReturnedGrnKeys(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
          )).thenAnswer((_) async => <String>{});

      await pumpApp(tester, const PurchaseReturnEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.text('Select a supplier to see their approved GRNs (billed or not).'), findsOneWidget);

      final supplierField = fieldInCard('Supplier', () => find.byType(TextFormField));
      await tester.enterText(supplierField, 'Test');
      await tester.pumpAndSettle();

      expect(find.text('[SUP-001] Test Supplier'), findsOneWidget);

      // tester.tap(find.text(...)) taps the center of the raw option text,
      // which can land outside its own hit area inside the overlay's
      // InkWell (Flutter warns "would not hit test", and onSelected never
      // fires) — target the InkWell itself instead.
      await tester.tap(find.ancestor(of: find.text('[SUP-001] Test Supplier'), matching: find.byType(InkWell)).first);
      // supplierField carries `key: ValueKey(_supplierDisplay ?? '')` —
      // selecting changes _supplierDisplay, forcing a remount.
      await tester.pumpAndSettle();

      // _onSupplierSelected sets _supplierId/_supplierDisplay and then
      // awaits getGrnsForSupplier/getFullyReturnedGrnKeys — the GRN picker
      // card swapping its "select a supplier" prompt for the fetched GRN's
      // own checkbox row (title is a plain Text of g['grn_no'], asserted
      // directly, same as the resume-flow test above) is the simplest
      // observable proof both the selection and its downstream fetch landed.
      expect(find.text('Select a supplier to see their approved GRNs (billed or not).'), findsNothing);
      expect(find.text('GRN-001'), findsOneWidget);
      expect(find.text('[SUP-001] Test Supplier'), findsOneWidget); // now the field's own displayed value
    });
  });
}
