import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/layout/screen_header.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/core/widgets/sakal_autocomplete.dart';
import 'package:sakal/core/widgets/sakal_field_card.dart';
import 'package:sakal/features/inventory/domain/repositories/material_requisition_repository.dart';
import 'package:sakal/features/inventory/presentation/providers/material_requisition_providers.dart';
import 'package:sakal/features/inventory/presentation/screens/material_requisition_entry_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockMaterialRequisitionRepository extends Mock implements MaterialRequisitionRepository {}

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
  late MockMaterialRequisitionRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
  });

  setUp(() {
    mockRepo = MockMaterialRequisitionRepository();
    when(() => mockRepo.getLocationsForIssue(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => [
          {'id': 'loc-001', 'location_name': 'Main Warehouse'},
          {'id': 'loc-002', 'location_name': 'Branch Store'},
        ]);
    when(() => mockRepo.getDepartments(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => [
          {'id': 'dept-001', 'description': 'Operations'},
        ]);
    when(() => mockRepo.getUsersForAutocomplete(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => [
          {'id': 'user-001', 'full_name': 'Test User'},
        ]);
  });

  List<Override> overrides() => [
        materialRequisitionRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  group('New (blank) requisition', () {
    testWidgets('renders the blank form with all key fields and no lines', (tester) async {
      await pumpApp(tester, const MaterialRequisitionEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      final header = _readHeader(tester, find.byType(MaterialRequisitionEntryScreen));
      expect(header?.title, 'New Material Requisition');
      expect(header?.subtitle, 'Unsaved draft');
      expect(_findFieldLabel('FROM LOCATION'), findsOneWidget);
      expect(_findFieldLabel('REQUISITION DATE'), findsOneWidget);
      expect(_findFieldLabel('REQUESTED BY'), findsOneWidget);
      expect(find.text('No lines yet — add a product.'), findsOneWidget);
      expect(find.text('Add Line'), findsOneWidget);
      expect(find.text('Save Draft'), findsOneWidget);
      expect(header?.actions.length, 1); // Save Draft now shows in the desktop TopBar
      expect(find.text('Approve'), findsNothing);
    });

    testWidgets('blocks save and shows a validation message when there are no lines', (tester) async {
      await pumpApp(tester, const MaterialRequisitionEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      expect(find.text('Add at least one line with a product and quantity.'), findsOneWidget);
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
            requisitionNo: any(named: 'requisitionNo'),
            requisitionDate: any(named: 'requisitionDate'),
          )).thenAnswer((_) async => {
            'requisition_no': 'MREQ-001',
            'requisition_date': '2026-07-01',
            'status': 'DRAFT',
            'location_id': 'loc-001',
            'requested_by': 'Jane Doe',
            'reason': 'Monthly stock replenishment',
            'remarks': 'Original remarks',
          });
      when(() => mockRepo.getLines(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            requisitionNo: any(named: 'requisitionNo'),
            requisitionDate: any(named: 'requisitionDate'),
          )).thenAnswer((_) async => [
            {
              'product_id': 'prod-001',
              'product': {'product_code': 'WID-A', 'product_name': 'Widget A'},
              'uom_id': 'uom-001',
              'uom': {'description': 'Piece'},
              'uom_conversion_factor': 1,
              'department_id': 'dept-001',
              'consumption_area_id': 'area-001',
              'issued_qty': 0,
              'barcode': null,
              'qty_pack': 10,
              'qty_loose': 0,
              'remarks': 'Line remark',
            },
          ]);
      when(() => mockRepo.getConsumptionAreasForDepartment(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            departmentId: any(named: 'departmentId'),
          )).thenAnswer((_) async => [
            {'id': 'area-001', 'description': 'Main Area'},
          ]);
    }

    testWidgets('loads and displays every field from the saved header and line', (tester) async {
      stubExistingDraft();

      await pumpApp(
        tester,
        const MaterialRequisitionEntryScreen(editRequisitionNo: 'MREQ-001', editRequisitionDate: '2026-07-01'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      final header = _readHeader(tester, find.byType(MaterialRequisitionEntryScreen));
      expect(header?.title, 'Material Requisition · MREQ-001');
      expect(header?.subtitle, 'Draft');
      expect(find.text('Main Warehouse'), findsOneWidget);
      expect(find.text('Monthly stock replenishment'), findsOneWidget);
      expect(find.textContaining('Widget A'), findsWidgets);
      expect(find.text('Piece'), findsOneWidget);
      expect(find.text('Operations'), findsOneWidget);
      expect(find.text('Main Area'), findsOneWidget);
      expect(find.text('Line remark'), findsOneWidget);
      expect(find.text('10'), findsOneWidget);
      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.text('Approve'), findsNothing);
    });

    testWidgets('editing the reason field and saving calls the repository with the updated payload', (tester) async {
      stubExistingDraft();
      when(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'MREQ-001');
      when(() => mockRepo.cacheRequisitionLocally(
            effectiveRequisitionNo: any(named: 'effectiveRequisitionNo'),
            header: any(named: 'header'),
            lines: any(named: 'lines'),
          )).thenAnswer((_) async {});

      await pumpApp(
        tester,
        const MaterialRequisitionEntryScreen(editRequisitionNo: 'MREQ-001', editRequisitionDate: '2026-07-01'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.text('Monthly stock replenishment'), 'Updated reason');
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
      expect(header['reason'], 'Updated reason');
      expect(lines, hasLength(1));
      expect(lines.first['product_id'], 'prod-001');
      expect(lines.first['department_id'], 'dept-001');
      expect(lines.first['consumption_area_id'], 'area-001');
      expect(lines.first['qty_pack'], 10.0);
      expect(lines.first['base_qty'], 10.0);

      expect(find.text('Material Requisition MREQ-001 saved.'), findsOneWidget);
    });
  });

  // Every prior test batch (Phase 4/5) deliberately excluded driving
  // SakalAutocomplete through real user interaction (type -> see filtered
  // options -> tap one) — this extends the pattern proven on Stock Transfer
  // Request's own pilot group to this screen's Product field.
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

      await pumpApp(tester, const MaterialRequisitionEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      // _addLine() adds a fresh blank row — this screen never auto-seeds
      // one, so "Add Line" is the only way to get a Product field into the
      // tree at all.
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
      // showModalBottomSheet with its own separate search field, ignoring
      // the outer field entirely — see journal_voucher_entry_screen_test.dart's
      // "Mobile picker" group), which would break this test's own
      // inline-overlay-based interaction below. '—' is unique on a fresh
      // blank line (only the Unit field ever shows it).
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

      await tester.tap(find.text('[WID-A] Widget A'));
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

    // A full-save round trip is deliberately skipped here — this screen's
    // save path requires a Department AND a Consumption Area on every line
    // (the latter loaded asynchronously off the former), which is out of
    // scope for this autocomplete-focused pass; the search+select test
    // above already proves the picker mechanics work end to end.
  });
}
