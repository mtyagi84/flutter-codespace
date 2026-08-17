import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/layout/screen_header.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/core/widgets/sakal_autocomplete.dart';
import 'package:sakal/features/inventory/domain/repositories/opening_stock_repository.dart';
import 'package:sakal/features/inventory/presentation/providers/opening_stock_providers.dart';
import 'package:sakal/features/inventory/presentation/screens/opening_stock_entry_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockOpeningStockRepository extends Mock implements OpeningStockRepository {}

class _FakeStringDynamicMap extends Fake implements Map<String, dynamic> {}
class _FakeStringDynamicMapList extends Fake implements List<Map<String, dynamic>> {}

Future<void> _pumpBriefly(WidgetTester tester, {int times = 5}) async {
  for (var i = 0; i < times; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder _findFieldLabel(String label) => find.byWidgetPredicate(
      (w) => w is RichText && w.maxLines == 1 && w.text.toPlainText().toUpperCase().contains(label.toUpperCase()),
    );

/// The screen's title/subtitle/badge no longer render as body text — they're
/// posted to the shared TopBar via ScreenHeaderMixin (screen_header.dart),
/// and pumpApp() doesn't include a TopBar in its pumped tree at all. Read
/// the posted ScreenHeaderInfo back from the provider instead of searching
/// for rendered text.
ScreenHeaderInfo? _readHeader(WidgetTester tester, Finder screenFinder) =>
    ProviderScope.containerOf(tester.element(screenFinder)).read(screenHeaderProvider);

void main() {
  late MockOpeningStockRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
  });

  setUp(() {
    mockRepo = MockOpeningStockRepository();
    when(() => mockRepo.getLocations(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => [
          {'id': 'loc-001', 'location_name': 'Main Warehouse'},
          {'id': 'loc-002', 'location_name': 'Branch Store'},
        ]);
    // _init() calls getUsers() unconditionally (before checking
    // widget.editOpeningNo) to resolve created_by/approved_by signature
    // names — an unstubbed Mock call throws MissingStubError, which was
    // silently caught by _init()'s own try/catch, leaving _openingNo null
    // forever. Invisible on the "New (blank)" tests (null is the correct
    // value there too) but broke every "resume flow" assertion that the
    // header title actually update.
    when(() => mockRepo.getUsers(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => []);
  });

  List<Override> overrides() => [
        openingStockRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  group('New (blank) opening stock', () {
    testWidgets('renders the blank form with all key fields and no lines', (tester) async {
      await pumpApp(tester, const OpeningStockEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      final header = _readHeader(tester, find.byType(OpeningStockEntryScreen));
      expect(header?.title, 'New Opening Stock');
      expect(header?.subtitle, 'Unsaved draft');
      expect(_findFieldLabel('Store / Location'), findsOneWidget);
      expect(_findFieldLabel('Opening Date'), findsOneWidget);
      expect(_findFieldLabel('Remarks'), findsOneWidget);
      expect(find.text('No lines yet — add a product, scan a barcode, or upload an Excel file.'), findsOneWidget);
      expect(find.text('Add Line'), findsOneWidget);
      expect(find.text('Save Draft'), findsOneWidget);
      // Default (desktop) viewport now routes Save Draft into the TopBar's
      // own header actions (button-consolidation rollout) — a brand-new,
      // never-saved opening stock has no Approve/Print yet (both require a
      // real openingNo), so exactly one action (Save Draft) is expected.
      expect(header?.actions.length, 1);
      expect(find.text('Approve'), findsNothing);
    });

    testWidgets('blocks save and shows a validation message when no location is selected', (tester) async {
      await pumpApp(tester, const OpeningStockEntryScreen(), overrides: overrides(), session: testSession(locationId: null));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      expect(find.text('Select a Store/Location.'), findsOneWidget);
      verifyNever(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            userId: any(named: 'userId'),
          ));
    });
  });

  group('Editing an existing DRAFT (resume flow)', () {
    void stubExistingDraft() {
      when(() => mockRepo.getHeader(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            openingNo: any(named: 'openingNo'),
            openingDate: any(named: 'openingDate'),
          )).thenAnswer((_) async => {
            'opening_no': 'OPN-001',
            'opening_date': '2026-07-01',
            'status': 'DRAFT',
            'location_id': 'loc-001',
            'remarks': 'Original remarks',
          });
      when(() => mockRepo.getLines(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            openingNo: any(named: 'openingNo'),
            openingDate: any(named: 'openingDate'),
          )).thenAnswer((_) async => [
            {
              'product_id': 'prod-001',
              'product': {'product_code': 'WID-A', 'product_name': 'Widget A', 'tracking_type': 'NONE'},
              'uom_id': 'uom-001',
              'uom': {'description': 'Piece'},
              'uom_conversion_factor': 1,
              'pack_qty': 10,
              'loose_qty': 0,
              'batch_no': null,
              'serial_no': null,
              'expiry_date': null,
              'manufacturing_date': null,
              'unit_cost': 25.5,
              'remarks': 'Line remark',
            },
          ]);
    }

    testWidgets('loads and displays every field from the saved header and line', (tester) async {
      stubExistingDraft();

      await pumpApp(
        tester,
        const OpeningStockEntryScreen(editOpeningNo: 'OPN-001', editOpeningDate: '2026-07-01'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      final header = _readHeader(tester, find.byType(OpeningStockEntryScreen));
      expect(header?.title, 'Opening Stock · OPN-001');
      expect(header?.subtitle, 'Draft');
      expect(find.text('Main Warehouse'), findsOneWidget);
      expect(find.text('Original remarks'), findsOneWidget);
      expect(find.textContaining('Widget A'), findsWidgets);
      expect(find.text('Piece'), findsOneWidget);
      expect(find.text('Line remark'), findsOneWidget);
      expect(find.text('10'), findsOneWidget);
      expect(find.text('25.5'), findsOneWidget);
      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.text('Approve'), findsNothing);
    });

    testWidgets('editing remarks and saving calls the repository with the updated payload', (tester) async {
      stubExistingDraft();
      when(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'OPN-001');
      when(() => mockRepo.cacheOpeningStockLocally(
            effectiveOpeningNo: any(named: 'effectiveOpeningNo'),
            header: any(named: 'header'),
            lines: any(named: 'lines'),
          )).thenAnswer((_) async {});

      await pumpApp(
        tester,
        const OpeningStockEntryScreen(editOpeningNo: 'OPN-001', editOpeningDate: '2026-07-01'),
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
            userId: any(named: 'userId'),
          )).captured;
      final header = captured[0] as Map<String, dynamic>;
      final lines = captured[1] as List<Map<String, dynamic>>;

      expect(header['location_id'], 'loc-001');
      expect(header['remarks'], 'Updated remarks');
      expect(lines, hasLength(1));
      expect(lines.first['product_id'], 'prod-001');
      expect(lines.first['pack_qty'], 10.0);
      expect(lines.first['base_qty'], 10.0);
      expect(lines.first['unit_cost'], 25.5);

      expect(find.text('Opening Stock OPN-001 saved.'), findsOneWidget);
    });
  });

  // Every prior test batch (Phase 4/5) deliberately excluded driving
  // SakalAutocomplete through real user interaction (type -> see filtered
  // options -> tap one) — this extends the pattern proven on Stock Transfer
  // Request's own pilot group to this screen's Product field. Uses an
  // untracked (tracking_type: NONE) product so no batch/serial/expiry entry
  // is ever triggered — that's a separate, out-of-scope work stream.
  group('Product autocomplete interaction (real search + select)', () {
    void stubProductSearch() {
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
              'tracking_type': 'NONE',
              'uom': {'description': 'Piece'},
            },
          ]);
    }

    testWidgets('typing into the Product field shows the matching option, and tapping it selects the product', (tester) async {
      stubProductSearch();
      // _refreshCurrentStock runs (unawaited) as soon as a product lands on
      // the row — advisory only (wrapped in its own try/catch on the
      // screen), but stub it anyway so the test isn't relying on that catch.
      when(() => mockRepo.getCurrentStockAndCost(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            locationId: any(named: 'locationId'),
            productId: any(named: 'productId'),
          )).thenAnswer((_) async => null);

      await pumpApp(tester, const OpeningStockEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      // _addLine() adds a fresh blank row — this screen never auto-seeds
      // one, so "Add Line" is the only way to get a Product field into the
      // tree at all (the other two ways — scan a barcode, upload Excel —
      // are separate, out-of-scope entry paths).
      await tester.tap(find.text('Add Line'));
      await tester.pumpAndSettle();

      // Before any product is picked, the Unit field reads its own
      // documented placeholder for "nothing selected yet". Asserted
      // unscoped (not via fieldInCard) — this screen ALSO has a "Unit
      // Cost" field on the same line, and _findFieldLabel's substring
      // match would treat "UNIT COST *" as matching a search for "Unit"
      // too. A fresh, untracked, pre-selection row has no other '—' on
      // screen (Expiry/Manufacturing Date only render once
      // row.isBatchTracked is true), so this is unambiguous as-is.
      expect(find.text('—'), findsOneWidget);

      // Can't use fieldInCard() here: the per-line "Product" label is
      // gated `showLabel: isMobile` and isn't built at this (non-mobile)
      // viewport. Product is the only SakalAutocomplete on a
      // freshly-added blank line.
      final productField = find.descendant(of: find.byType(SakalAutocomplete<Map<String, dynamic>>), matching: find.byType(TextFormField));
      await tester.enterText(productField, 'Widget');
      // Lets the async optionsBuilder -> getProductsForPicker(search:
      // 'Widget') resolve and RawAutocomplete's OverlayEntry render the
      // options list.
      await tester.pumpAndSettle();

      // The overlay's own option row (no optionBuilder passed on this
      // screen's SakalAutocomplete -> falls back to a plain Text of
      // displayStringForOption) — this is the exact string
      // `_onProductSelected` will also set as the row's productDisplay.
      expect(find.text('[WID-A] Widget A'), findsOneWidget);

      // tester.tap(find.text(...)) taps the center of the raw option text,
      // which can land outside its own hit area inside the overlay's
      // InkWell (Flutter warns "would not hit test", and onSelected never
      // fires) — target the InkWell itself instead.
      await tester.tap(find.ancestor(of: find.text('[WID-A] Widget A'), matching: find.byType(InkWell)).first);
      // The field's own `key: ValueKey('${row.hashCode}-${row.productDisplay}')`
      // forces a remount once productDisplay changes — pumpAndSettle lets
      // that remount (and the Unit field's own rebuild) finish.
      await tester.pumpAndSettle();

      // _onProductSelected sets row.productId/productDisplay/uomId/uomLabel
      // — the Unit field (a plain readOnly SakalFieldCard bound to
      // row.uomLabel) is the simplest observable proof the selection
      // actually landed, without needing to save and inspect a payload.
      // Asserted unscoped for the same "Unit" vs "Unit Cost" ambiguity
      // reason as above — 'Piece' is unique on screen regardless.
      expect(find.text('Piece'), findsOneWidget);
      expect(find.text('[WID-A] Widget A'), findsOneWidget); // now the field's own displayed value, not an overlay option
    });

    testWidgets('selecting a product via autocomplete then saving (with a required unit cost) includes it in the payload', (tester) async {
      stubProductSearch();
      when(() => mockRepo.getCurrentStockAndCost(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            locationId: any(named: 'locationId'),
            productId: any(named: 'productId'),
          )).thenAnswer((_) async => null);
      when(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'OPN-002');
      when(() => mockRepo.cacheOpeningStockLocally(
            effectiveOpeningNo: any(named: 'effectiveOpeningNo'),
            header: any(named: 'header'),
            lines: any(named: 'lines'),
          )).thenAnswer((_) async {});

      await pumpApp(tester, const OpeningStockEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      // Store/Location already defaults to session.locationId ('loc-001').
      await tester.tap(find.text('Add Line'));
      await tester.pumpAndSettle();

      // Can't use fieldInCard() here or below — per-line labels are gated
      // `showLabel: isMobile` and aren't built at this (non-mobile)
      // viewport. Product is the only SakalAutocomplete on a
      // freshly-added blank line; the line's own Row (its immediate
      // ancestor) then scopes the remaining fields by position — barcode
      // isn't part of this screen's line row at all, so the TextFormField
      // order within it is Product, Qty Pack, Qty Loose, Unit Cost,
      // Remarks (showLooseQty is true per testSession()'s own default).
      final productField = find.descendant(of: find.byType(SakalAutocomplete<Map<String, dynamic>>), matching: find.byType(TextFormField));
      await tester.enterText(productField, 'Widget');
      await tester.pumpAndSettle();
      // tester.tap(find.text(...)) taps the center of the raw option text,
      // which can land outside its own hit area inside the overlay's
      // InkWell (Flutter warns "would not hit test", and onSelected never
      // fires) — target the InkWell itself instead.
      await tester.tap(find.ancestor(of: find.text('[WID-A] Widget A'), matching: find.byType(InkWell)).first);
      await tester.pumpAndSettle();

      final lineRow = find.ancestor(of: find.byType(SakalAutocomplete<Map<String, dynamic>>), matching: find.byType(Row)).first;
      final lineTextFields = find.descendant(of: lineRow, matching: find.byType(TextFormField));

      // testSession()'s UserSession defaults qtyEntryMode to
      // 'PACK_AND_LOOSE' (not 'PACK_ONLY'), so showLooseQty is true and the
      // field's label is 'Qty Pack', never the bare 'Quantity' fallback.
      final qtyField = lineTextFields.at(1);
      await tester.enterText(qtyField, '5');
      await tester.pump();

      // Unlike every other module in this rollout, Opening Stock requires a
      // user-entered unit cost per line (it's the one document establishing
      // cost for the first time) — _saveDraft blocks with no cost typed.
      final unitCostField = lineTextFields.at(3);
      await tester.enterText(unitCostField, '25.5');
      await tester.pump();

      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      final captured = verify(() => mockRepo.save(
            header: captureAny(named: 'header'),
            lines: captureAny(named: 'lines'),
            userId: any(named: 'userId'),
          )).captured;
      final header = captured[0] as Map<String, dynamic>;
      final lines = captured[1] as List<Map<String, dynamic>>;

      expect(header['location_id'], 'loc-001');
      expect(lines, hasLength(1));
      expect(lines.first['product_id'], 'prod-001');
      expect(lines.first['pack_qty'], 5.0);
      expect(lines.first['base_qty'], 5.0);
      expect(lines.first['unit_cost'], 25.5);

      expect(find.text('Opening Stock OPN-002 saved.'), findsOneWidget);
    });
  });
}
