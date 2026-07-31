import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/providers/master_cache_providers.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/core/widgets/sakal_field_card.dart';
import 'package:sakal/features/sales/domain/repositories/price_master_repository.dart';
import 'package:sakal/features/sales/presentation/providers/price_master_providers.dart';
import 'package:sakal/features/sales/presentation/screens/price_master_entry_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockPriceMasterRepository extends Mock implements PriceMasterRepository {}

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
  late MockPriceMasterRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
  });

  setUp(() {
    mockRepo = MockPriceMasterRepository();
  });

  // Unlike every other Sales entry screen tested so far, this one is a
  // pricing BATCH (product+price rows), not a header+lines document with
  // GL/stock impact — but it still has the same DRAFT/APPROVED lifecycle
  // (Save Draft / Approve, resumable by entry_no+entry_date), so the same
  // 4-test shape (blank render / validation / resume / save) still fits,
  // just with "at least one priced line" as the validation gate instead of
  // "a selected customer/invoice".
  List<Override> overrides() => [
        priceMasterRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
        locationsProvider.overrideWith((ref) async => [
              {'id': 'loc-001', 'location_name': 'Main Branch'},
            ]),
        currenciesProvider.overrideWith((ref) async => [
              {'id': 'ccy-usd', 'currency_id': 'USD'},
              {'id': 'ccy-fc', 'currency_id': 'FC'},
            ]),
        baseCurrencyProvider.overrideWith((ref) async => 'USD'),
        localCurrencyProvider.overrideWith((ref) async => 'FC'),
      ];

  // _init() always calls getProductsForPicker/getReasons first, regardless
  // of new-vs-edit mode.
  void stubBaseline() {
    when(() => mockRepo.getProductsForPicker(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => [
              {'id': 'prod-001', 'product_code': 'WID-A', 'product_name': 'Widget A', 'cost_currency_id': 'ccy-usd'},
            ]);
    when(() => mockRepo.getReasons(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => []);
  }

  group('New (blank) Price Master batch', () {
    testWidgets('renders the blank batch form with all key fields and no lines yet', (tester) async {
      stubBaseline();

      await pumpApp(tester, const PriceMasterEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      expect(find.text('New Price Master Batch'), findsOneWidget);
      expect(find.text('Unsaved draft'), findsOneWidget);

      expect(_findFieldLabel('ENTRY NO'), findsOneWidget);
      expect(_findFieldLabel('ENTRY DATE'), findsOneWidget);
      expect(_findFieldLabel('EFFECTIVE DATE'), findsOneWidget);
      expect(_findFieldLabel('LOCATION'), findsOneWidget);
      expect(_findFieldLabel('CURRENCY'), findsOneWidget);
      expect(_findFieldLabel('RATE TO BASE'), findsOneWidget);
      expect(_findFieldLabel('REMARKS'), findsOneWidget);

      expect(find.text('(auto on save)'), findsOneWidget); // Entry No read-only placeholder
      expect(find.text('Main Branch'), findsOneWidget); // Location dropdown, defaulted from session
      expect(find.text('USD'), findsOneWidget); // Currency dropdown, defaulted to base currency
      expect(find.text('Generic'), findsOneWidget);
      expect(find.text('Customer-Specific'), findsOneWidget);

      expect(find.text('Lines'), findsOneWidget);
      expect(find.text('No lines yet — add a product or scan a barcode.'), findsOneWidget);
      expect(find.text('Add Line'), findsOneWidget);

      expect(find.text('Save Draft'), findsOneWidget);
      // A brand-new, never-saved batch has no entry number yet, so no print
      // button; canApprove also defaults false from the harness's empty
      // menuProvider, so no Approve button either.
      expect(find.text('Approve'), findsNothing);
      expect(find.byIcon(Icons.print_outlined), findsNothing);
    });

    testWidgets('blocks save and shows a validation message when no lines are added', (tester) async {
      stubBaseline();

      await pumpApp(tester, const PriceMasterEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      // _saveDraft() checks Location, then Currency, then Price Type (both
      // already valid/defaulted here), then requires at least one line with
      // a product+UOM — still empty on a blank batch.
      expect(find.text('Add at least one line with a product and UOM.'), findsOneWidget);
      verifyNever(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            userId: any(named: 'userId'),
          ));
    });
  });

  group('Editing an existing DRAFT (resume flow, one Generic line)', () {
    void stubExistingDraft() {
      when(() => mockRepo.getHeader(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            entryNo: any(named: 'entryNo'),
            entryDate: any(named: 'entryDate'),
          )).thenAnswer((_) async => {
                'entry_no': 'PM-001',
                'entry_date': '2026-07-20',
                'effective_date': '2026-07-25',
                'status': 'DRAFT',
                'location_id': 'loc-001',
                'price_type': 'GENERIC',
                'customer_id': null,
                'customer': null,
                'price_currency_id': 'ccy-usd',
                'currency': {'currency_id': 'USD'},
                'rate_to_base': 1,
                'rate_to_local': 2,
                'remarks': 'Original remarks',
              });
      when(() => mockRepo.getLines(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            entryNo: any(named: 'entryNo'),
            entryDate: any(named: 'entryDate'),
          )).thenAnswer((_) async => [
                {
                  'product_id': 'prod-001',
                  'product': {'product_code': 'WID-A', 'product_name': 'Widget A', 'cost_currency_id': 'ccy-usd'},
                  'uom_id': 'uom-001',
                  'uom': {'description': 'Piece'},
                  'uom_conversion_factor': 1,
                  'barcode': null,
                  'cost_price': 50.0,
                  'margin_percent': 20.0,
                  'selling_price': 60.0,
                  'below_cost_reason_id': null,
                  'is_tax_inclusive': false,
                  'remarks': 'Line remark A',
                },
              ]);
      when(() => mockRepo.getProductUoms(any())).thenAnswer((_) async => [
            {
              'uom_id': 'uom-001',
              'uom': {'description': 'Piece'},
              'conversion_factor': 1,
              'is_base_uom': true,
            },
          ]);
    }

    testWidgets('loads and displays every field from the saved header and line', (tester) async {
      stubBaseline();
      stubExistingDraft();

      await pumpApp(
        tester,
        const PriceMasterEntryScreen(editEntryNo: 'PM-001', editEntryDate: '2026-07-20'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      expect(find.text('Sales Price Master · PM-001'), findsOneWidget);
      expect(find.text('Draft'), findsOneWidget);
      expect(find.text('PM-001'), findsOneWidget); // Entry No read-only field
      expect(find.text('20 Jul 2026'), findsOneWidget); // Entry Date
      expect(find.text('25 Jul 2026'), findsOneWidget); // Effective Date
      expect(find.text('Main Branch'), findsOneWidget); // Location dropdown
      expect(find.text('USD'), findsOneWidget); // Currency dropdown
      expect(find.text('1'), findsOneWidget); // Rate to Base (currency == base, rate stays 1)
      expect(find.text('Original remarks'), findsOneWidget);

      // Loaded line, re-enriched with its own UOM candidate list.
      expect(find.text('1. [WID-A] Widget A'), findsOneWidget); // line card title
      expect(find.text('[WID-A] Widget A'), findsOneWidget); // product autocomplete field text
      expect(find.text('Piece'), findsOneWidget); // UOM dropdown selection
      expect(find.text('50.00'), findsOneWidget); // Cost Price (read-only, toStringAsFixed(2))
      expect(find.text('20.0'), findsOneWidget); // Margin %
      expect(find.text('60.0'), findsOneWidget); // Selling Price

      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.text('Approve'), findsNothing); // canApprove defaults false from the harness's empty menuProvider
      expect(find.byIcon(Icons.print_outlined), findsOneWidget); // a saved batch is printable regardless of status
    });

    testWidgets('editing remarks and saving calls the repository with the updated payload', (tester) async {
      stubBaseline();
      stubExistingDraft();
      when(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'PM-001');
      when(() => mockRepo.cacheBatchLocally(
            effectiveEntryNo: any(named: 'effectiveEntryNo'),
            header: any(named: 'header'),
            lines: any(named: 'lines'),
          )).thenAnswer((_) async {});

      await pumpApp(
        tester,
        const PriceMasterEntryScreen(editEntryNo: 'PM-001', editEntryDate: '2026-07-20'),
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

      expect(header['client_id'], 'client-001');
      expect(header['company_id'], 'company-001');
      expect(header['entry_no'], 'PM-001');
      expect(header['entry_date'], '2026-07-20');
      expect(header['location_id'], 'loc-001');
      expect(header['price_type'], 'GENERIC');
      expect(header['customer_id'], null);
      expect(header['effective_date'], '2026-07-25');
      expect(header['price_currency_id'], 'ccy-usd');
      expect(header['rate_to_base'], 1.0);
      expect(header['rate_to_local'], 2.0);
      expect(header['remarks'], 'Updated remarks');

      expect(lines, hasLength(1));
      final line = lines.first;
      expect(line['serial_no'], 1);
      expect(line['product_id'], 'prod-001');
      expect(line['uom_id'], 'uom-001');
      expect(line['uom_conversion_factor'], 1.0);
      expect(line['barcode'], null);
      expect(line['cost_price'], 50.0);
      expect(line['margin_percent'], 20.0);
      expect(line['selling_price'], 60.0);
      expect(line['below_cost_reason_id'], null);
      expect(line['is_tax_inclusive'], false);
      expect(line['remarks'], 'Line remark A');

      expect(find.text('Price Master batch PM-001 saved.'), findsOneWidget);
    });
  });

  // Every prior Price Master test batch (Phase 5) deliberately excluded
  // driving SakalAutocomplete through real user interaction — this group
  // drives the screen's own Product picker on a freshly added line
  // (`_buildLinesCard`'s productField). Unlike GRN/Sales Invoice, this
  // screen's optionsBuilder filters an already-loaded `_products` list
  // purely client-side/synchronously (`_ds.getProductsForPicker()` is
  // called once in _init(), no `search:` per keystroke) — so
  // pumpAndSettle() after typing is only needed to let RawAutocomplete's
  // own OverlayEntry render, not to resolve a real async gap.
  group('Product autocomplete interaction on a freshly added line (real search + select)', () {
    // Stricter than a plain "contains" label match — see
    // grn_entry_screen_test.dart's own identical helper for the full
    // rationale (SakalFieldCard appends a child TextSpan(' *') for
    // required fields).
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

    testWidgets('typing into the Product field on a freshly added line shows the matching option, and selecting it loads UOM options and Cost Price',
        (tester) async {
      stubBaseline(); // getProductsForPicker() -> one product, WID-A, cost_currency_id ccy-usd
      when(() => mockRepo.getProductUoms('prod-001')).thenAnswer((_) async => [
            {
              'uom_id': 'uom-001',
              'uom': {'description': 'Piece'},
              'conversion_factor': 1,
              'is_base_uom': true,
            },
          ]);
      when(() => mockRepo.getProductLocationCost(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            locationId: any(named: 'locationId'),
            productId: any(named: 'productId'),
          )).thenAnswer((_) async => {'cost_price': 45.0, 'cost_price_specific': null});

      await pumpApp(tester, const PriceMasterEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add Line'));
      await tester.pumpAndSettle();

      // Before any product is picked, the fresh line's own title falls
      // back to 'New Line' (`'${idx+1}. ${row.productDisplay.isEmpty ?
      // 'New Line' : row.productDisplay}'`).
      expect(find.text('1. New Line'), findsOneWidget);

      final productField = fieldInCard('Product', () => find.byType(TextFormField));
      await tester.enterText(productField, 'Widget');
      await tester.pumpAndSettle();

      expect(find.text('[WID-A] Widget A'), findsOneWidget);

      await tester.tap(find.text('[WID-A] Widget A'));
      // The Product field carries `key: ValueKey('${row.hashCode}-${row.productDisplay}')`
      // — selecting a product changes productDisplay, forcing a remount;
      // pumpAndSettle also lets the two chained async calls
      // (_loadUomOptions then _refreshLineCost) resolve.
      await tester.pumpAndSettle();

      // _onProductSelected sets row.productId/productDisplay (used
      // directly in the SakalLineItemCard's own title), then
      // _loadUomOptions auto-selects the single base UOM candidate, then
      // _refreshLineCost resolves Cost Price — currency defaults to base
      // (USD) on a new batch, so the three-way rule's first branch
      // applies directly: resolvedCost = cost_price (45.0).
      expect(find.text('1. [WID-A] Widget A'), findsOneWidget);
      expect(find.text('Piece'), findsOneWidget); // UOM dropdown, auto-selected
      expect(find.text('45.00'), findsOneWidget); // Cost Price, read-only, toStringAsFixed(2)
    });
  });
}
