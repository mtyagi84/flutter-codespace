import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
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
      (w) => w is RichText && w.text.toPlainText().toUpperCase().contains(label.toUpperCase()),
    );

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

      expect(find.text('New Material Requisition'), findsOneWidget);
      expect(find.text('Unsaved draft'), findsOneWidget);
      expect(_findFieldLabel('FROM LOCATION'), findsOneWidget);
      expect(_findFieldLabel('REQUISITION DATE'), findsOneWidget);
      expect(_findFieldLabel('REQUESTED BY'), findsOneWidget);
      expect(find.text('No lines yet — add a product.'), findsOneWidget);
      expect(find.text('Add Line'), findsOneWidget);
      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.byIcon(Icons.print_outlined), findsNothing);
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

      expect(find.text('Material Requisition · MREQ-001'), findsOneWidget);
      expect(find.text('Draft'), findsOneWidget);
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
}
