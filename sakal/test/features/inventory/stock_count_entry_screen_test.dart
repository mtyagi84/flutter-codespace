import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/features/inventory/domain/repositories/stock_count_repository.dart';
import 'package:sakal/features/inventory/presentation/providers/stock_count_providers.dart';
import 'package:sakal/features/inventory/presentation/screens/stock_count_entry_screen.dart';
import 'package:sakal/features/master/domain/repositories/item_categories_repository.dart';
import 'package:sakal/features/master/presentation/providers/item_categories_providers.dart';

import '../../test_helpers/pump_app.dart';

class MockStockCountRepository extends Mock implements StockCountRepository {}

class MockItemCategoriesRepository extends Mock implements ItemCategoriesRepository {}

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

void main() {
  late MockStockCountRepository mockRepo;
  late MockItemCategoriesRepository mockCategoriesRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
  });

  setUp(() {
    mockRepo = MockStockCountRepository();
    mockCategoriesRepo = MockItemCategoriesRepository();
    when(() => mockRepo.getLocations(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => [
          {'id': 'loc-001', 'location_name': 'Main Warehouse'},
          {'id': 'loc-002', 'location_name': 'Branch Store'},
        ]);
    when(() => mockCategoriesRepo.getCategories(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => []);
  });

  List<Override> overrides() => [
        stockCountRepositoryProvider.overrideWithValue(mockRepo),
        itemCategoriesRepositoryProvider.overrideWithValue(mockCategoriesRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  group('New (blank) count — blind worksheet not yet started', () {
    testWidgets('renders the blank form with key fields and a Start Count action, no lines/Save/print yet', (tester) async {
      await pumpApp(tester, const StockCountEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      expect(find.text('New Stock Count'), findsOneWidget);
      expect(find.text('Unsaved draft'), findsOneWidget);
      expect(_findFieldLabel('Count No'), findsOneWidget);
      expect(_findFieldLabel('Store / Location'), findsOneWidget);
      expect(_findFieldLabel('Count Date'), findsOneWidget);
      expect(_findFieldLabel('Category (All if blank)'), findsOneWidget);
      expect(_findFieldLabel('Item Type (All if blank)'), findsOneWidget);
      expect(_findFieldLabel('Remarks'), findsOneWidget);

      // Worksheet not started yet — only the Start Count CTA is shown, no
      // lines card, no Save Draft (the whole action-buttons row is gated
      // on _hasStarted), no print icon (nothing saved yet), no Submit.
      expect(find.text('Start Count'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.text('Save Draft'), findsNothing);
      expect(find.text('Submit'), findsNothing);
      expect(find.byIcon(Icons.print_outlined), findsNothing);
    });

    testWidgets('blocks Start Count and shows a validation message when no location is selected', (tester) async {
      await pumpApp(
        tester,
        const StockCountEntryScreen(),
        overrides: overrides(),
        session: testSession(locationId: null),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Start Count'));
      await _pumpBriefly(tester);

      expect(find.text('Select a Store/Location.'), findsOneWidget);
      verifyNever(() => mockRepo.getEligibleProducts(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            categoryId: any(named: 'categoryId'),
            nature: any(named: 'nature'),
          ));
    });
  });

  group('Resuming an existing DRAFT count (blind — no system quantities anywhere)', () {
    void stubExistingDraft() {
      when(() => mockRepo.getHeader(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            countNo: any(named: 'countNo'),
            countDate: any(named: 'countDate'),
          )).thenAnswer((_) async => {
            'count_no': 'CNT-001',
            'count_date': '2026-07-01',
            'status': 'DRAFT',
            'location_id': 'loc-001',
            'category_filter_id': null,
            'nature_filter': null,
            'remarks': 'Original remarks',
          });
      when(() => mockRepo.getLines(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            countNo: any(named: 'countNo'),
            countDate: any(named: 'countDate'),
          )).thenAnswer((_) async => [
            {
              'product_id': 'prod-001',
              'product': {
                'product_code': 'WID-A',
                'product_name': 'Widget A',
                'tracking_type': 'NONE',
                'barcode': null,
                'part_number': null,
              },
              'uom_id': 'uom-001',
              'uom': {'description': 'Piece'},
              'uom_conversion_factor': 1,
              'is_counted': true,
              'counted_qty_pack': 10,
              'counted_qty_loose': 0,
              'barcode': '',
              'serial_no': 1,
            },
          ]);
    }

    testWidgets('loads and displays the saved header + counted line — no system qty field exists to leak', (tester) async {
      stubExistingDraft();

      await pumpApp(
        tester,
        const StockCountEntryScreen(editCountNo: 'CNT-001', editCountDate: '2026-07-01'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.text('Stock Count · CNT-001'), findsOneWidget);
      expect(find.text('Draft'), findsOneWidget);
      expect(find.text('Main Warehouse'), findsOneWidget);
      expect(find.text('Original remarks'), findsOneWidget);
      expect(find.textContaining('Widget A'), findsWidgets);
      expect(find.text('Piece'), findsOneWidget);
      expect(find.text('Worksheet — 1 of 1 counted'), findsOneWidget);
      expect(find.text('10'), findsOneWidget);

      // Blind count — nothing on this screen ever shows a system quantity.
      expect(find.textContaining('System'), findsNothing);

      expect(find.text('Save Draft'), findsOneWidget);
      // canApprove defaults false with an empty menuProvider — Submit stays hidden.
      expect(find.text('Submit'), findsNothing);
    });

    testWidgets('editing remarks and saving Draft calls the repository with the updated payload', (tester) async {
      stubExistingDraft();
      when(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'CNT-001');
      when(() => mockRepo.cacheStockCountLocally(
            effectiveCountNo: any(named: 'effectiveCountNo'),
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
          )).thenAnswer((_) async {});

      await pumpApp(
        tester,
        const StockCountEntryScreen(editCountNo: 'CNT-001', editCountDate: '2026-07-01'),
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
            userId: any(named: 'userId'),
          )).captured;
      final header = captured[0] as Map<String, dynamic>;
      final lines = captured[1] as List<Map<String, dynamic>>;

      expect(header['count_no'], 'CNT-001');
      expect(header['location_id'], 'loc-001');
      expect(header['remarks'], 'Updated remarks');
      expect(lines, hasLength(1));
      expect(lines.first['product_id'], 'prod-001');
      expect(lines.first['is_counted'], true);
      expect(lines.first['counted_qty_pack'], 10.0);
      expect(lines.first['counted_base_qty'], 10.0);

      expect(find.text('Stock Count CNT-001 saved.'), findsOneWidget);
    });
  });
}
