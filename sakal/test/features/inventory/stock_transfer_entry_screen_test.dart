import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/core/widgets/sakal_field_card.dart';
import 'package:sakal/features/inventory/domain/repositories/stock_transfer_repository.dart';
import 'package:sakal/features/inventory/presentation/providers/stock_transfer_providers.dart';
import 'package:sakal/features/inventory/presentation/screens/stock_transfer_entry_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockStockTransferRepository extends Mock implements StockTransferRepository {}

class _FakeStringDynamicMap extends Fake implements Map<String, dynamic> {}
class _FakeStringDynamicMapList extends Fake implements List<Map<String, dynamic>> {}

Future<void> _pumpBriefly(WidgetTester tester, {int times = 5}) async {
  for (var i = 0; i < times; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder _findFieldLabel(String label) => find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText().toUpperCase().contains(label.toUpperCase()),
    );

void main() {
  late MockStockTransferRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
  });

  setUp(() {
    mockRepo = MockStockTransferRepository();
    when(() => mockRepo.getLocations(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => [
          {'id': 'loc-001', 'location_name': 'Main Warehouse'},
          {'id': 'loc-002', 'location_name': 'Branch Store'},
        ]);
    when(() => mockRepo.getInterLocationModel(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => 'SIMPLE');
    when(() => mockRepo.getAdditionalCharges(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => []);
    when(() => mockRepo.getCostPrices(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          locationId: any(named: 'locationId'),
          productIds: any(named: 'productIds'),
        )).thenAnswer((_) async => <String, num>{});
  });

  List<Override> overrides() => [
        stockTransferRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  group('New (blank) transfer', () {
    testWidgets('renders the blank form with all key fields, empty lines, and the charges section', (tester) async {
      await pumpApp(tester, const StockTransferEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      expect(find.text('New Stock Transfer'), findsOneWidget);
      expect(find.text('Unsaved draft'), findsOneWidget);
      expect(_findFieldLabel('MODE'), findsOneWidget);
      expect(_findFieldLabel('FROM LOCATION'), findsOneWidget);
      expect(_findFieldLabel('TO LOCATION'), findsOneWidget);
      expect(_findFieldLabel('TRANSFER NO'), findsOneWidget);
      expect(_findFieldLabel('TRANSFER DATE'), findsOneWidget);
      expect(_findFieldLabel('REMARKS'), findsOneWidget);

      expect(find.text('Transfer Lines'), findsOneWidget);
      expect(find.text('No lines yet — add a product.'), findsOneWidget);
      expect(find.text('Add Line'), findsOneWidget);

      // Charges section is always present, even when empty.
      expect(find.text('Additional Charges'), findsOneWidget);
      expect(find.text('No additional charges (freight, loading, handling…).'), findsOneWidget);
      expect(find.text('Add Charge'), findsNothing); // no configured charge types in this fixture

      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.byIcon(Icons.print_outlined), findsNothing);
      expect(find.text('Approve'), findsNothing);
    });

    testWidgets('blocks save and shows a validation message when locations are incomplete', (tester) async {
      await pumpApp(tester, const StockTransferEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      expect(find.text('Select both From Location and To Location.'), findsOneWidget);
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

  group('Editing an existing DRAFT (resume flow, DIRECT mode)', () {
    void stubExistingDraft() {
      when(() => mockRepo.getHeader(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            transferNo: any(named: 'transferNo'),
            transferDate: any(named: 'transferDate'),
          )).thenAnswer((_) async => {
            'transfer_no': 'ST-001',
            'transfer_date': '2026-07-01',
            'status': 'DRAFT',
            'from_location_id': 'loc-001',
            'to_location_id': 'loc-002',
            'against_request': false,
            'source_request_no': null,
            'source_request_date': null,
            'remarks': 'Original remarks',
          });
      when(() => mockRepo.getLines(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            transferNo: any(named: 'transferNo'),
            transferDate: any(named: 'transferDate'),
          )).thenAnswer((_) async => [
            {
              'product_id': 'prod-001',
              'product': {'product_code': 'WID-A', 'product_name': 'Widget A', 'tracking_type': 'NONE'},
              'uom_id': 'uom-001',
              'uom': {'description': 'Piece'},
              'uom_conversion_factor': 1,
              'qty_pack': 10,
              'qty_loose': 0,
              'remarks': 'Line remark',
              'charge_amount': 0,
            },
          ]);
      when(() => mockRepo.getCharges(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            transferNo: any(named: 'transferNo'),
            transferDate: any(named: 'transferDate'),
          )).thenAnswer((_) async => []);
    }

    testWidgets('loads and displays every field from the saved header and line', (tester) async {
      stubExistingDraft();

      await pumpApp(
        tester,
        const StockTransferEntryScreen(editTransferNo: 'ST-001', editTransferDate: '2026-07-01'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.text('Stock Transfer · ST-001'), findsOneWidget);
      expect(find.text('Draft'), findsOneWidget);
      expect(find.text('Main Warehouse'), findsOneWidget);
      expect(find.text('Branch Store'), findsOneWidget);
      expect(find.text('Original remarks'), findsOneWidget);
      expect(find.textContaining('Widget A'), findsWidgets);
      expect(find.text('Piece'), findsOneWidget);
      expect(find.text('Line remark'), findsOneWidget);
      // _TransferLineRow's qtyPackCtrl always formats with toStringAsFixed(2).
      expect(find.text('10.00'), findsOneWidget);
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
            charges: any(named: 'charges'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'ST-001');
      when(() => mockRepo.cacheTransferLocally(
            effectiveTransferNo: any(named: 'effectiveTransferNo'),
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            charges: any(named: 'charges'),
          )).thenAnswer((_) async {});

      await pumpApp(
        tester,
        const StockTransferEntryScreen(editTransferNo: 'ST-001', editTransferDate: '2026-07-01'),
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
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            charges: any(named: 'charges'),
            userId: any(named: 'userId'),
          )).captured;
      final header = captured[0] as Map<String, dynamic>;
      final lines = captured[1] as List<Map<String, dynamic>>;

      expect(header['from_location_id'], 'loc-001');
      expect(header['to_location_id'], 'loc-002');
      expect(header['remarks'], 'Updated remarks');
      expect(header['against_request'], false);
      expect(lines, hasLength(1));
      expect(lines.first['product_id'], 'prod-001');
      expect(lines.first['qty_pack'], 10.0);
      expect(lines.first['base_qty'], 10.0);

      expect(find.text('Stock Transfer ST-001 saved.'), findsOneWidget);
    });
  });

  // Every prior test batch (Phase 4/5) deliberately excluded driving
  // SakalAutocomplete through real user interaction (type -> see filtered
  // options -> tap one) — this extends the pattern proven on Stock Transfer
  // Request's own pilot group to this screen's Product field, DIRECT mode
  // only (AGAINST_REQUEST mode is a separate, out-of-scope work stream).
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

    testWidgets('typing into the Product field shows the matching option, and tapping it selects the product', (tester) async {
      stubProductSearch();

      await pumpApp(tester, const StockTransferEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      // Screen defaults to DIRECT mode — _addDirectLine() adds a fresh
      // blank row, the only way to get a Product field into the tree.
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
      // that remount (and the Unit field's own rebuild, plus the unawaited
      // _refreshCostPrices() this screen also fires) finish.
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

    testWidgets('selecting a product via autocomplete then saving includes it in the payload', (tester) async {
      stubProductSearch();
      when(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            charges: any(named: 'charges'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'ST-002');
      when(() => mockRepo.cacheTransferLocally(
            effectiveTransferNo: any(named: 'effectiveTransferNo'),
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            charges: any(named: 'charges'),
          )).thenAnswer((_) async {});

      await pumpApp(tester, const StockTransferEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      // From Location already defaults to session.locationId ('loc-001') —
      // only To Location needs picking.
      final toLocationDropdown = fieldInCard('To Location', () => find.byType(DropdownButtonFormField<String>));
      await tester.tap(toLocationDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Branch Store').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add Line'));
      await tester.pumpAndSettle();

      final productField = fieldInCard('Product', () => find.byType(TextFormField));
      await tester.enterText(productField, 'Widget');
      await tester.pumpAndSettle();
      await tester.tap(find.text('[WID-A] Widget A'));
      await tester.pumpAndSettle();

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
            charges: any(named: 'charges'),
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

      expect(find.text('Stock Transfer ST-002 saved.'), findsOneWidget);
    });
  });
}
