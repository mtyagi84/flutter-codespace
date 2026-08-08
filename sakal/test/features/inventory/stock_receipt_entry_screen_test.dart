import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/layout/screen_header.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/features/inventory/domain/repositories/stock_receipt_repository.dart';
import 'package:sakal/features/inventory/presentation/providers/stock_receipt_providers.dart';
import 'package:sakal/features/inventory/presentation/screens/stock_receipt_entry_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockStockReceiptRepository extends Mock implements StockReceiptRepository {}

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
  late MockStockReceiptRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
  });

  setUp(() {
    mockRepo = MockStockReceiptRepository();
    when(() => mockRepo.getReceivableTransfers(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => []);
  });

  List<Override> overrides() => [
        stockReceiptRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  group('New (blank) receipt', () {
    testWidgets('renders the blank form with all key fields and no Lines card yet (consolidation-only screen)', (tester) async {
      await pumpApp(tester, const StockReceiptEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      final header = _readHeader(tester, find.byType(StockReceiptEntryScreen));
      expect(header?.title, 'New Stock Receipt');
      expect(header?.subtitle, 'Unsaved draft');
      expect(_findFieldLabel('SOURCE TRANSFER'), findsOneWidget);
      expect(find.text('(select below)'), findsOneWidget);
      expect(_findFieldLabel('FROM LOCATION'), findsOneWidget);
      expect(_findFieldLabel('TO LOCATION'), findsOneWidget);
      expect(_findFieldLabel('RECEIPT NO'), findsOneWidget);
      expect(_findFieldLabel('RECEIPT DATE'), findsOneWidget);
      expect(_findFieldLabel('REMARKS'), findsOneWidget);

      // Transfer picker card — this screen consolidates from a Stock
      // Transfer, there is no free-text "Add Line" affordance anywhere.
      expect(find.text('Approved Stock Transfers Awaiting Receipt'), findsOneWidget);
      expect(find.text('No approved transfers awaiting receipt.'), findsOneWidget);

      // No Lines card at all until a transfer is picked — divergence from
      // the pilot / Stock Transfer screen, which always shows a Lines card
      // (with an empty-state message) even before any product is added.
      expect(find.text('Receipt Lines'), findsNothing);
      expect(find.text('Add Line'), findsNothing);

      expect(find.text('Save Draft'), findsOneWidget);
      expect(header?.actions, isEmpty);
      expect(find.text('Approve'), findsNothing);
    });

    testWidgets('blocks save and shows a validation message when no transfer is selected', (tester) async {
      await pumpApp(tester, const StockReceiptEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      expect(find.text('Select a Stock Transfer to receive.'), findsOneWidget);
      verifyNever(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            userId: any(named: 'userId'),
          ));
    });
  });

  group('Editing an existing DRAFT (resume flow — consolidated from a Stock Transfer)', () {
    void stubExistingDraft() {
      when(() => mockRepo.getHeader(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            receiptNo: any(named: 'receiptNo'),
            receiptDate: any(named: 'receiptDate'),
          )).thenAnswer((_) async => {
            'receipt_no': 'SRC-001',
            'receipt_date': '2026-07-05',
            'status': 'DRAFT',
            'source_transfer_no': 'ST-001',
            'source_transfer_date': '2026-07-01',
            'from_location': {'location_name': 'Main Warehouse'},
            'to_location': {'location_name': 'Branch Store'},
            'remarks': 'Receipt remarks',
          });
      when(() => mockRepo.getTransferLines(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            transferNo: any(named: 'transferNo'),
            transferDate: any(named: 'transferDate'),
          )).thenAnswer((_) async => [
            {'serial_no': 1, 'base_qty': 10, 'barcode': null},
          ]);
      when(() => mockRepo.getLines(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            receiptNo: any(named: 'receiptNo'),
            receiptDate: any(named: 'receiptDate'),
          )).thenAnswer((_) async => [
            {
              'source_transfer_line_serial': 1,
              'product_id': 'prod-001',
              'product': {'product_code': 'WID-A', 'product_name': 'Widget A', 'tracking_type': 'NONE'},
              'uom_id': 'uom-001',
              'uom': {'description': 'Piece'},
              'uom_conversion_factor': 1,
              'received_qty_pack': 10,
              'received_qty_loose': 0,
              'remarks': 'Line remark',
            },
          ]);
    }

    testWidgets('loads and displays every field from the saved header, source transfer, and line', (tester) async {
      stubExistingDraft();

      await pumpApp(
        tester,
        const StockReceiptEntryScreen(editReceiptNo: 'SRC-001', editReceiptDate: '2026-07-05'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      final header = _readHeader(tester, find.byType(StockReceiptEntryScreen));
      expect(header?.title, 'Stock Receipt · SRC-001');
      expect(header?.subtitle, 'Draft');
      expect(find.text('ST-001'), findsOneWidget); // Source Transfer read-only value
      expect(find.text('Main Warehouse'), findsOneWidget);
      expect(find.text('Branch Store'), findsOneWidget);
      expect(find.text('Receipt remarks'), findsOneWidget);

      expect(find.text('Receipt Lines'), findsOneWidget);
      expect(find.textContaining('Widget A'), findsWidgets);
      expect(find.text('Piece'), findsOneWidget);
      // _ReceiptLineRow's qtyPackCtrl always formats with toStringAsFixed(2).
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
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'SRC-001');
      when(() => mockRepo.cacheReceiptLocally(
            effectiveReceiptNo: any(named: 'effectiveReceiptNo'),
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
          )).thenAnswer((_) async {});

      await pumpApp(
        tester,
        const StockReceiptEntryScreen(editReceiptNo: 'SRC-001', editReceiptDate: '2026-07-05'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.text('Receipt remarks'), 'Updated remarks');
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

      expect(header['source_transfer_no'], 'ST-001');
      expect(header['source_transfer_date'], '2026-07-01');
      expect(header['remarks'], 'Updated remarks');
      expect(header['receipt_no'], 'SRC-001');
      expect(lines, hasLength(1));
      expect(lines.first['product_id'], 'prod-001');
      expect(lines.first['received_qty_pack'], 10.0);
      expect(lines.first['received_base_qty'], 10.0);
      expect(lines.first['barcode'], '');

      expect(find.text('Stock Receipt SRC-001 saved.'), findsOneWidget);
    });
  });
}
