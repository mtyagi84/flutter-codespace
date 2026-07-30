import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
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

void main() {
  late MockStockTransferRequestRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
  });

  setUp(() {
    mockRepo = MockStockTransferRequestRepository();
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

      expect(find.text('New Stock Transfer Request'), findsOneWidget);
      expect(find.text('Unsaved draft'), findsOneWidget);
      expect(find.textContaining('FROM LOCATION'), findsOneWidget);
      expect(find.textContaining('TO LOCATION'), findsOneWidget);
      expect(find.textContaining('REQUEST DATE'), findsOneWidget);
      expect(find.text('No lines yet — add a product.'), findsOneWidget);
      expect(find.text('Add Line'), findsOneWidget);
      expect(find.text('Save Draft'), findsOneWidget);
      // A brand-new, never-saved request has no request number yet, so no
      // print button and no approve button (approve requires !_isNew).
      expect(find.byIcon(Icons.print_outlined), findsNothing);
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

      expect(find.text('Stock Transfer Request · STR-001'), findsOneWidget);
      expect(find.text('Draft'), findsOneWidget);
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
}
