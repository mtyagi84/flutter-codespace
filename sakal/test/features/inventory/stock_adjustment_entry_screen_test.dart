import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
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

Finder _findFieldLabel(String label) => find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText().toUpperCase().contains(label.toUpperCase()),
    );

void main() {
  late MockStockAdjustmentRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
  });

  setUp(() {
    mockRepo = MockStockAdjustmentRepository();
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

      expect(find.text('New Stock Adjustment'), findsOneWidget);
      expect(find.text('Unsaved draft'), findsOneWidget);
      expect(_findFieldLabel('Store / Location'), findsOneWidget);
      expect(_findFieldLabel('Adjustment Date'), findsOneWidget);
      expect(_findFieldLabel('Reason'), findsOneWidget);
      expect(_findFieldLabel('Remarks'), findsOneWidget);
      expect(find.text('No lines yet — add a product.'), findsOneWidget);
      expect(find.text('Add Line'), findsOneWidget);
      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.byIcon(Icons.print_outlined), findsNothing);
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

      expect(find.text('Stock Adjustment · ADJ-001'), findsOneWidget);
      expect(find.text('Draft'), findsOneWidget);
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
}
