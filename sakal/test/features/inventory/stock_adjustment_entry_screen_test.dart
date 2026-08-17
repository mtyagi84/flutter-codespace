import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/layout/screen_header.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/core/widgets/sakal_field_card.dart';
import 'package:sakal/features/inventory/domain/repositories/stock_adjustment_repository.dart';
import 'package:sakal/features/inventory/presentation/providers/stock_adjustment_providers.dart';
import 'package:sakal/features/inventory/presentation/screens/stock_adjustment_entry_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockStockAdjustmentRepository extends Mock implements StockAdjustmentRepository {}

class _FakeStringDynamicMap extends Fake implements Map<String, dynamic> {}
class _FakeStringDynamicMapList extends Fake implements List<Map<String, dynamic>> {}

Future<void> _pumpBriefly(WidgetTester tester, {int times = 5}) async {
  for (var i = 0; i < times; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Line items now branch on `Responsive.isMobile` (<600px) — the default
/// flutter_test viewport (~800x600) is BELOW the app's 1024px desktop
/// breakpoint used elsewhere but ABOVE this feature's own 600px threshold,
/// so lines render on the DESKTOP branch there. Tests that need the mobile
/// `SakalLineItemCard` branch specifically (e.g. its own title text) must
/// force a narrow viewport.
void _useMobileViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
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
  late MockStockAdjustmentRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
  });

  setUp(() {
    mockRepo = MockStockAdjustmentRepository();
    // _init() calls getUsersForAutocomplete() unconditionally to resolve
    // signature names — an unstubbed Mock call throws, silently caught by
    // _init()'s own try/catch, which broke every resume-flow assertion
    // depending on post-load state (e.g. the header title).
    when(() => mockRepo.getUsersForAutocomplete(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => []);
    when(() => mockRepo.getLocations(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => [
          {'id': 'loc-001', 'location_name': 'Main Warehouse'},
          {'id': 'loc-002', 'location_name': 'Branch Store'},
        ]);
    when(() => mockRepo.getReasons(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => [
          {'id': 'reason-001', 'description': 'Physical Count Variance'},
        ]);
  });

  List<Override> overrides() => [
        stockAdjustmentRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  group('New (blank) adjustment', () {
    testWidgets('renders the blank form with all key fields and no lines', (tester) async {
      await pumpApp(tester, const StockAdjustmentEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      final header = _readHeader(tester, find.byType(StockAdjustmentEntryScreen));
      expect(header?.title, 'New Stock Adjustment');
      expect(header?.subtitle, 'Unsaved draft');
      expect(_findFieldLabel('Store / Location'), findsOneWidget);
      expect(_findFieldLabel('Adjustment Date'), findsOneWidget);
      expect(_findFieldLabel('Reason'), findsOneWidget);
      expect(_findFieldLabel('Remarks'), findsOneWidget);
      expect(find.text('No lines yet — add a product.'), findsOneWidget);
      expect(find.text('Add Line'), findsOneWidget);
      expect(find.text('Save Draft'), findsOneWidget);
      // Default (desktop) viewport now routes Save Draft into the TopBar's
      // own header actions (button-consolidation rollout) — a brand-new,
      // never-saved adjustment has no Approve/Print yet (both require a
      // real adjustmentNo), so exactly one action (Save Draft) is expected.
      expect(header?.actions.length, 1);
      expect(find.text('Approve'), findsNothing);
    });

    testWidgets('blocks save and shows a validation message when no location is selected', (tester) async {
      await pumpApp(tester, const StockAdjustmentEntryScreen(), overrides: overrides(), session: testSession(locationId: null));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      expect(find.text('Select a Store/Location.'), findsOneWidget);
      verifyNever(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            userId: any(named: 'userId'),
          ));
    });
  });

  group('Editing an existing DRAFT (resume flow)', () {
    void stubExistingDraft() {
      when(() => mockRepo.getHeader(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            adjustmentNo: any(named: 'adjustmentNo'),
            adjustmentDate: any(named: 'adjustmentDate'),
          )).thenAnswer((_) async => {
            'adjustment_no': 'ADJ-001',
            'adjustment_date': '2026-07-01',
            'status': 'DRAFT',
            'location_id': 'loc-001',
            'reason_id': 'reason-001',
            'remarks': 'Original remarks',
          });
      when(() => mockRepo.getLines(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            adjustmentNo: any(named: 'adjustmentNo'),
            adjustmentDate: any(named: 'adjustmentDate'),
          )).thenAnswer((_) async => [
            {
              'product_id': 'prod-001',
              'product': {'product_code': 'WID-A', 'product_name': 'Widget A', 'tracking_type': 'NONE'},
              'uom_id': 'uom-001',
              'uom': {'description': 'Piece'},
              'uom_conversion_factor': 1,
              'adjust_flag': '-',
              'system_qty': 15,
              'barcode': null,
              'reason_id': null,
              'qty_pack': 5,
              'qty_loose': 0,
              'remarks': 'Line remark',
            },
          ]);
    }

    testWidgets('loads and displays every field from the saved header and line', (tester) async {
      stubExistingDraft();

      await pumpApp(
        tester,
        const StockAdjustmentEntryScreen(editAdjustmentNo: 'ADJ-001', editAdjustmentDate: '2026-07-01'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      final header = _readHeader(tester, find.byType(StockAdjustmentEntryScreen));
      expect(header?.title, 'Stock Adjustment · ADJ-001');
      expect(header?.subtitle, 'Draft');
      expect(find.text('Main Warehouse'), findsOneWidget);
      expect(find.text('Physical Count Variance'), findsOneWidget);
      expect(find.text('Original remarks'), findsOneWidget);
      expect(find.textContaining('Widget A'), findsWidgets);
      expect(find.text('Piece'), findsOneWidget);
      expect(find.text('Line remark'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.text('Approve'), findsNothing);
    });

    testWidgets('editing remarks and saving calls the repository with the updated payload', (tester) async {
      stubExistingDraft();
      when(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'ADJ-001');
      when(() => mockRepo.cacheAdjustmentLocally(
            effectiveAdjustmentNo: any(named: 'effectiveAdjustmentNo'),
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
          )).thenAnswer((_) async {});

      await pumpApp(
        tester,
        const StockAdjustmentEntryScreen(editAdjustmentNo: 'ADJ-001', editAdjustmentDate: '2026-07-01'),
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
            batches: captureAny(named: 'batches'),
            serials: captureAny(named: 'serials'),
            userId: any(named: 'userId'),
          )).captured;
      final header = captured[0] as Map<String, dynamic>;
      final lines = captured[1] as List<Map<String, dynamic>>;
      final batches = captured[2] as List<Map<String, dynamic>>;
      final serials = captured[3] as List<Map<String, dynamic>>;

      expect(header['location_id'], 'loc-001');
      expect(header['reason_id'], 'reason-001');
      expect(header['remarks'], 'Updated remarks');
      expect(lines, hasLength(1));
      expect(lines.first['product_id'], 'prod-001');
      expect(lines.first['qty_pack'], 5.0);
      expect(lines.first['base_qty'], 5.0);
      expect(lines.first['adjust_flag'], '-');
      expect(lines.first['system_qty'], 15.0);
      expect(batches, isEmpty);
      expect(serials, isEmpty);

      expect(find.text('Stock Adjustment ADJ-001 saved.'), findsOneWidget);
    });
  });

  // Every prior test batch (Phase 4/5) deliberately excluded driving
  // SakalAutocomplete through real user interaction (type -> see filtered
  // options -> tap one) — this extends the pattern proven on Stock Transfer
  // Request's own pilot group to this screen's Product field. Uses an
  // untracked (tracking_type: NONE) product so no batch/serial UI is ever
  // triggered — that's a separate, out-of-scope work stream.
  group('Product autocomplete interaction (real search + select)', () {
    Finder fieldInCard(String label, Finder Function() matcher) => find.descendant(
          of: find.ancestor(of: _findFieldLabel(label), matching: find.byType(SakalFieldCard)).first,
          matching: matcher(),
        );

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

    testWidgets('typing into the Product field shows the matching option, and tapping it selects the product on a "+" line', (tester) async {
      // This test's final assertion counts 2 occurrences of the product's
      // display text — one from the field itself, one from the
      // SakalLineItemCard's own title (this screen's title has no index
      // prefix, so it exact-matches) — which only renders on the mobile
      // branch.
      _useMobileViewport(tester);
      stubProductSearch();
      // _refreshSystemQty runs (unawaited) as soon as a product lands on
      // the row — advisory only (wrapped in its own try/catch on the
      // screen), but stub it anyway so the test isn't relying on that catch.
      when(() => mockRepo.getCurrentStock(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            locationId: any(named: 'locationId'),
            productId: any(named: 'productId'),
          )).thenAnswer((_) async => 0);

      await pumpApp(tester, const StockAdjustmentEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      // _addLine() adds a fresh blank row, defaulting adjustFlag to '+'
      // (Increase) — this is already the "+" line the task calls for, no
      // Direction dropdown change needed.
      await tester.tap(find.text('Add Line'));
      await tester.pumpAndSettle();

      // Before any product is picked, the Unit field reads its own
      // documented placeholder for "nothing selected yet".
      expect(fieldInCard('Unit', () => find.text('—')), findsOneWidget);

      final productField = fieldInCard('Product', () => find.byType(TextFormField));
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

      await tester.tap(find.text('[WID-A] Widget A'));
      // The field's own `key: ValueKey('${row.hashCode}-${row.productDisplay}')`
      // forces a remount once productDisplay changes — pumpAndSettle lets
      // that remount (and the Unit field's own rebuild) finish.
      await tester.pumpAndSettle();

      // _onProductSelected sets row.productId/productDisplay/uomId/uomLabel
      // — the Unit field (a plain readOnly SakalFieldCard bound to
      // row.uomLabel) is the simplest observable proof the selection
      // actually landed, without needing to save and inspect a payload.
      expect(fieldInCard('Unit', () => find.text('Piece')), findsOneWidget);
      // Now matches both the field's own displayed value AND the
      // SakalLineItemCard's own title (bound to the same productDisplay).
      expect(find.text('[WID-A] Widget A'), findsNWidgets(2));
    });

    testWidgets('selecting a product via autocomplete on a "+" line then saving includes it in the payload', (tester) async {
      stubProductSearch();
      when(() => mockRepo.getCurrentStock(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            locationId: any(named: 'locationId'),
            productId: any(named: 'productId'),
          )).thenAnswer((_) async => 0);
      when(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'ADJ-002');
      when(() => mockRepo.cacheAdjustmentLocally(
            effectiveAdjustmentNo: any(named: 'effectiveAdjustmentNo'),
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
          )).thenAnswer((_) async {});

      await pumpApp(tester, const StockAdjustmentEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      // Header Reason is picked FIRST, before any line exists — the line
      // grid's own per-line "Reason (override)" field also renders a label
      // containing "Reason", so picking the header field first avoids any
      // ambiguity between the two.
      final reasonDropdown = fieldInCard('Reason', () => find.byType(DropdownButtonFormField<String>));
      await tester.tap(reasonDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Physical Count Variance').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add Line'));
      await tester.pumpAndSettle();

      final productField = fieldInCard('Product', () => find.byType(TextFormField));
      await tester.enterText(productField, 'Widget');
      await tester.pumpAndSettle();
      await tester.tap(find.text('[WID-A] Widget A'));
      await tester.pumpAndSettle();

      // testSession()'s UserSession defaults qtyEntryMode to
      // 'PACK_AND_LOOSE' (not 'PACK_ONLY'), so showLooseQty is true and the
      // field's label is 'Qty Pack', never the bare 'Quantity' fallback.
      final qtyField = fieldInCard('Qty Pack', () => find.byType(TextFormField));
      await tester.enterText(qtyField, '5');
      await tester.pump();

      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      final captured = verify(() => mockRepo.save(
            header: captureAny(named: 'header'),
            lines: captureAny(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            userId: any(named: 'userId'),
          )).captured;
      final header = captured[0] as Map<String, dynamic>;
      final lines = captured[1] as List<Map<String, dynamic>>;

      expect(header['location_id'], 'loc-001');
      expect(header['reason_id'], 'reason-001');
      expect(lines, hasLength(1));
      expect(lines.first['product_id'], 'prod-001');
      expect(lines.first['qty_pack'], 5.0);
      expect(lines.first['base_qty'], 5.0);
      expect(lines.first['adjust_flag'], '+');

      expect(find.text('Stock Adjustment ADJ-002 saved.'), findsOneWidget);
    });
  });
}
