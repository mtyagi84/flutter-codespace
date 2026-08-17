import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/layout/screen_header.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/core/widgets/sakal_autocomplete.dart';
import 'package:sakal/core/widgets/sakal_field_card.dart';
import 'package:sakal/features/inventory/domain/repositories/stock_transfer_request_repository.dart';
import 'package:sakal/features/inventory/presentation/providers/stock_transfer_request_providers.dart';
import 'package:sakal/features/inventory/presentation/screens/stock_transfer_request_entry_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockStockTransferRequestRepository extends Mock implements StockTransferRequestRepository {}

// mocktail needs a registered fallback value for any() used on a Map/List
// argument matcher in a `verify()` call — Map/List aren't "known" types it
// can auto-generate a dummy for.
class _FakeStringDynamicMap extends Fake implements Map<String, dynamic> {}
class _FakeStringDynamicMapList extends Fake implements List<Map<String, dynamic>> {}

/// `pumpAndSettle()` right after an action that shows a SnackBar is a real
/// trap: it keeps pumping until every animation/timer settles, which
/// includes the SnackBar's own auto-dismiss timer (default ~4s) — by the
/// time it returns, the very text the test wants to assert on may already
/// be gone. A few short, bounded pumps let any pending async work (a
/// mocked repository call, a setState rebuild) resolve without running
/// anywhere near that long, so the SnackBar is still on screen afterward.
Future<void> _pumpBriefly(WidgetTester tester, {int times = 5}) async {
  for (var i = 0; i < times; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// SakalFieldCard renders its label as a raw `RichText` (root TextSpan +
/// an optional " *" child span for required fields), not wrapped in a
/// `Text`/`Text.rich` widget — `find.text()`/`find.textContaining()` only
/// reliably match `Text`/`EditableText`, not an arbitrary bare `RichText`
/// built this way. Matching directly against the RichText's own
/// `TextSpan.toPlainText()` sidesteps that ambiguity entirely.
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
  late MockStockTransferRequestRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
  });

  setUp(() {
    mockRepo = MockStockTransferRequestRepository();
    // _init() also calls getUsersForAutocomplete() unconditionally to
    // resolve signature names — an unstubbed Mock call throws, silently
    // caught by _init()'s own try/catch, which broke every resume-flow
    // assertion depending on post-load state (e.g. the header title).
    when(() => mockRepo.getUsersForAutocomplete(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => []);
    // Every test in this file reaches _init(), which always calls
    // getLocations() first regardless of new-vs-edit mode.
    when(() => mockRepo.getLocations(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => [
          {'id': 'loc-001', 'location_name': 'Main Warehouse'},
          {'id': 'loc-002', 'location_name': 'Branch Store'},
        ]);
  });

  List<Override> overrides() => [
        stockTransferRequestRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  group('New (blank) request', () {
    testWidgets('renders the blank form with all key fields and no lines', (tester) async {
      await pumpApp(tester, const StockTransferRequestEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      // Rules out "the header card just never left its _loading state" as
      // an alternative explanation for the label checks below — the title
      // block renders unconditionally, but the header/lines cards (and
      // their field labels) only render once _init() has finished.
      expect(find.byType(CircularProgressIndicator), findsNothing);

      final header = _readHeader(tester, find.byType(StockTransferRequestEntryScreen));
      expect(header?.title, 'New Stock Transfer Request');
      expect(header?.subtitle, 'Unsaved draft');
      expect(_findFieldLabel('FROM LOCATION'), findsOneWidget);
      expect(_findFieldLabel('TO LOCATION'), findsOneWidget);
      expect(_findFieldLabel('REQUEST DATE'), findsOneWidget);
      expect(find.text('No lines yet — add a product.'), findsOneWidget);
      expect(find.text('Add Line'), findsOneWidget);
      expect(find.text('Save Draft'), findsOneWidget);
      // A brand-new, never-saved request has no request number yet, so no
      // print button and no approve button (approve requires !_isNew). Default
      // (desktop) viewport now routes Save Draft into the TopBar's own header
      // actions (button-consolidation rollout) — exactly one action expected.
      expect(header?.actions.length, 1);
      expect(find.text('Approve'), findsNothing);
    });

    testWidgets('blocks save and shows a validation message when no locations are selected', (tester) async {
      await pumpApp(tester, const StockTransferRequestEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      expect(find.text('Select both From Location and To Location.'), findsOneWidget);
      verifyNever(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            userId: any(named: 'userId'),
          ));
    });
  });

  group('Editing an existing DRAFT (resume flow)', () {
    // Real, recurring bug class in this app (see CLAUDE.md's MANDATORY
    // pre-completion self-check) — a screen working right after creation
    // but silently losing data on resume. This is exactly the scenario
    // that class of bug hides in, so it's the pilot's main focus alongside
    // the simpler render/validation cases above.
    void stubExistingDraft() {
      when(() => mockRepo.getHeader(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            requestNo: any(named: 'requestNo'),
            requestDate: any(named: 'requestDate'),
          )).thenAnswer((_) async => {
            'request_no': 'STR-001',
            'request_date': '2026-07-01',
            'status': 'DRAFT',
            'from_location_id': 'loc-001',
            'to_location_id': 'loc-002',
            'remarks': 'Original remarks',
          });
      when(() => mockRepo.getLines(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            requestNo: any(named: 'requestNo'),
            requestDate: any(named: 'requestDate'),
          )).thenAnswer((_) async => [
            {
              'product_id': 'prod-001',
              'product': {'product_code': 'WID-A', 'product_name': 'Widget A'},
              'uom_id': 'uom-001',
              'uom': {'description': 'Piece'},
              'uom_conversion_factor': 1,
              'transferred_qty': 0,
              'qty_pack': 10,
              'qty_loose': 0,
              'remarks': 'Line remark',
            },
          ]);
    }

    testWidgets('loads and displays every field from the saved header and line', (tester) async {
      stubExistingDraft();

      await pumpApp(
        tester,
        const StockTransferRequestEntryScreen(editRequestNo: 'STR-001', editRequestDate: '2026-07-01'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      final header = _readHeader(tester, find.byType(StockTransferRequestEntryScreen));
      expect(header?.title, 'Stock Transfer Request · STR-001');
      expect(header?.subtitle, 'Draft');
      expect(find.text('Main Warehouse'), findsOneWidget); // From Location, resolved from location_id
      expect(find.text('Branch Store'), findsOneWidget);   // To Location
      expect(find.text('Original remarks'), findsOneWidget);
      // Line card: title includes the product display, unit and remarks
      // both come through, and quantity round-trips via the qtyPackCtrl.
      expect(find.textContaining('Widget A'), findsWidgets);
      expect(find.text('Piece'), findsOneWidget);
      expect(find.text('Line remark'), findsOneWidget);
      expect(find.text('10'), findsOneWidget);
      // A DRAFT is still editable, so the approve button shows (canApprove
      // defaults false from the harness's empty menuProvider, so it's
      // actually hidden here — only Save Draft should be visible).
      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.text('Approve'), findsNothing);
    });

    testWidgets('editing remarks and saving calls the repository with the updated payload', (tester) async {
      stubExistingDraft();
      when(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'STR-001');
      when(() => mockRepo.cacheRequestLocally(
            effectiveRequestNo: any(named: 'effectiveRequestNo'),
            header: any(named: 'header'),
            lines: any(named: 'lines'),
          )).thenAnswer((_) async {});

      await pumpApp(
        tester,
        const StockTransferRequestEntryScreen(editRequestNo: 'STR-001', editRequestDate: '2026-07-01'),
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

      expect(header['from_location_id'], 'loc-001');
      expect(header['to_location_id'], 'loc-002');
      expect(header['remarks'], 'Updated remarks');
      expect(lines, hasLength(1));
      expect(lines.first['product_id'], 'prod-001');
      expect(lines.first['qty_pack'], 10.0);
      expect(lines.first['base_qty'], 10.0);

      expect(find.text('Stock Transfer Request STR-001 saved.'), findsOneWidget);
    });
  });

  // Every prior test batch (Phase 4/5) deliberately excluded driving
  // SakalAutocomplete through real user interaction (type -> see filtered
  // options -> tap one) — this group is the pilot proving that pattern
  // actually works, before rolling it out to every other screen with a
  // product/customer/account picker. SakalAutocomplete's optionsBuilder is
  // async (FutureOr<Iterable<T>>, matching Flutter's own
  // AutocompleteOptionsBuilder typedef) and calls the repository on every
  // keystroke, so `pumpAndSettle()` (not a bounded `_pumpBriefly`) is the
  // right tool here — there's no lingering SnackBar timer to race, just a
  // one-shot Future to let resolve.
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
              'uom': {'description': 'Piece'},
            },
          ]);
    }

    testWidgets('typing into the Product field shows the matching option, and tapping it selects the product', (tester) async {
      stubProductSearch();

      await pumpApp(tester, const StockTransferRequestEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      // _addLine() adds a fresh blank row — this screen never auto-seeds
      // one (unlike GRN/PO/Sales Order/Sales Quotation), so "Add Line" is
      // the only way to get a Product field into the tree at all.
      await tester.tap(find.text('Add Line'));
      await tester.pumpAndSettle();

      // Before any product is picked, the Unit field reads its own
      // documented placeholder for "nothing selected yet". Can't use
      // fieldInCard() here (or below, for Product): per-line field labels
      // are gated `showLabel: isMobile`, so at this test's default
      // (non-mobile) viewport the label RichText isn't built at all —
      // there's no in-card label to anchor an ancestor lookup on. A forced
      // mobile viewport isn't the fix either: SakalAutocomplete forks its
      // WHOLE rendering path on isMobile (inline overlay vs. a
      // showModalBottomSheet with its own separate search field), which
      // would break this test's own inline-overlay-based interaction
      // below. '—' is unique on a fresh blank line (only the Unit field
      // ever shows it).
      expect(find.text('—'), findsOneWidget);

      // Product is the only SakalAutocomplete on a freshly-added blank line.
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
      expect(find.text('Piece'), findsOneWidget);
      expect(find.text('[WID-A] Widget A'), findsOneWidget); // now the field's own displayed value, not an overlay option
    });

    testWidgets('selecting a product via autocomplete then saving includes it in the payload', (tester) async {
      stubProductSearch();
      when(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'STR-002');
      when(() => mockRepo.cacheRequestLocally(
            effectiveRequestNo: any(named: 'effectiveRequestNo'),
            header: any(named: 'header'),
            lines: any(named: 'lines'),
          )).thenAnswer((_) async {});

      await pumpApp(tester, const StockTransferRequestEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      // From Location already defaults to session.locationId ('loc-001') —
      // only To Location needs picking. A plain DropdownButtonFormField
      // (not SakalAutocomplete), so the standard tap-to-open ->
      // tap-the-menu-item pattern applies, no new mechanics needed.
      final toLocationDropdown = fieldInCard('To Location', () => find.byType(DropdownButtonFormField<String>));
      await tester.tap(toLocationDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Branch Store').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add Line'));
      await tester.pumpAndSettle();

      // Can't use fieldInCard() here — see the same-named group's first
      // test above for why (per-line labels are gated `showLabel: isMobile`
      // and a mobile viewport would break inline-overlay selection below).
      final productField = find.descendant(of: find.byType(SakalAutocomplete<Map<String, dynamic>>), matching: find.byType(TextFormField));
      await tester.enterText(productField, 'Widget');
      await tester.pumpAndSettle();
      // tester.tap(find.text(...)) taps the center of the raw option text,
      // which can land outside its own hit area inside the overlay's
      // InkWell (Flutter warns "would not hit test", and onSelected never
      // fires) — target the InkWell itself instead.
      await tester.tap(find.ancestor(of: find.text('[WID-A] Widget A'), matching: find.byType(InkWell)).first);
      await tester.pumpAndSettle();

      // testSession()'s UserSession defaults qtyEntryMode to
      // 'PACK_AND_LOOSE' (not 'PACK_ONLY'), so showLooseQty is true and the
      // field's label is 'Qty Pack', never the bare 'Quantity' fallback.
      // Same fieldInCard() limitation as above — scope to the line's own
      // Row (barcode is off by default, so field order within it is
      // Product, Qty Pack, Qty Loose, Remarks) and pick Qty Pack by index.
      final lineRow = find.ancestor(of: find.byType(SakalAutocomplete<Map<String, dynamic>>), matching: find.byType(Row)).first;
      final qtyField = find.descendant(of: lineRow, matching: find.byType(TextFormField)).at(1);
      await tester.enterText(qtyField, '5');
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

      expect(header['from_location_id'], 'loc-001');
      expect(header['to_location_id'], 'loc-002');
      expect(lines, hasLength(1));
      expect(lines.first['product_id'], 'prod-001');
      expect(lines.first['qty_pack'], 5.0);
      expect(lines.first['base_qty'], 5.0);

      expect(find.text('Stock Transfer Request STR-002 saved.'), findsOneWidget);
    });
  });
}
