import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/features/inventory/domain/repositories/material_issue_repository.dart';
import 'package:sakal/features/inventory/presentation/providers/material_issue_providers.dart';
import 'package:sakal/features/inventory/presentation/screens/material_issue_entry_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockMaterialIssueRepository extends Mock implements MaterialIssueRepository {}

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
  late MockMaterialIssueRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
  });

  setUp(() {
    mockRepo = MockMaterialIssueRepository();
  });

  List<Override> overrides() => [
        materialIssueRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  group('New (blank) issue', () {
    testWidgets('renders the blank form with all key fields and no lines', (tester) async {
      when(() => mockRepo.getFulfillableRequisitions(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            locationId: any(named: 'locationId'),
          )).thenAnswer((_) async => []);

      await pumpApp(tester, const MaterialIssueEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      expect(find.text('New Material Issue'), findsOneWidget);
      expect(find.text('Unsaved draft'), findsOneWidget);
      expect(_findFieldLabel('ISSUE NO'), findsOneWidget);
      expect(_findFieldLabel('ISSUE DATE'), findsOneWidget);
      expect(_findFieldLabel('REMARKS'), findsOneWidget);
      expect(find.text('(auto on save)'), findsOneWidget);
      expect(find.text('Fulfillable Requisitions'), findsOneWidget);
      expect(find.text('No fulfillable requisitions at this location.'), findsOneWidget);
      expect(find.text('No lines yet — pick a requisition above.'), findsOneWidget);
      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.byIcon(Icons.print_outlined), findsNothing);
      expect(find.text('Approve'), findsNothing);
    });

    testWidgets('blocks save and shows a validation message when there are no issuable lines', (tester) async {
      when(() => mockRepo.getFulfillableRequisitions(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            locationId: any(named: 'locationId'),
          )).thenAnswer((_) async => []);

      await pumpApp(tester, const MaterialIssueEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      expect(find.text('Enter an issue quantity for at least one line.'), findsOneWidget);
      verifyNever(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            userId: any(named: 'userId'),
          ));
    });
  });

  group('Editing an existing DRAFT + consolidating a requisition (resume flow)', () {
    void stubExistingDraft() {
      when(() => mockRepo.getHeader(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            issueNo: any(named: 'issueNo'),
            issueDate: any(named: 'issueDate'),
          )).thenAnswer((_) async => {
            'issue_no': 'MISS-001',
            'issue_date': '2026-07-01',
            'status': 'DRAFT',
            'location_id': 'loc-001',
            'location': {'location_name': 'Main Warehouse'},
            'remarks': 'Existing issue remarks',
          });
      when(() => mockRepo.getFulfillableRequisitions(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            locationId: any(named: 'locationId'),
          )).thenAnswer((_) async => [
            {
              'requisition_no': 'MREQ-001',
              'requisition_date': '2026-07-01',
              'requested_by': 'Jane Doe',
              'status': 'APPROVED',
            },
          ]);
      when(() => mockRepo.getRequisitionLines(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            requisitionNo: any(named: 'requisitionNo'),
            requisitionDate: any(named: 'requisitionDate'),
          )).thenAnswer((_) async => [
            {
              'serial_no': 1,
              'base_qty': 10,
              'issued_qty': 0,
              'product_id': 'prod-001',
              'product': {'product_code': 'WID-A', 'product_name': 'Widget A', 'tracking_type': 'NONE'},
              'uom_id': 'uom-001',
              'uom': {'description': 'Piece'},
              'uom_conversion_factor': 1,
              'department_id': 'dept-001',
              'department': {'description': 'Operations'},
              'consumption_area_id': 'area-001',
              'area': {'description': 'Main Area'},
              'barcode': null,
            },
          ]);
    }

    testWidgets('loads the saved header, then consolidates a checked requisition into lines', (tester) async {
      stubExistingDraft();

      await pumpApp(
        tester,
        const MaterialIssueEntryScreen(editIssueNo: 'MISS-001', editIssueDate: '2026-07-01'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.text('Material Issue · MISS-001'), findsOneWidget);
      expect(find.text('Draft'), findsOneWidget);
      expect(find.text('Existing issue remarks'), findsOneWidget);
      expect(find.text('MREQ-001'), findsOneWidget);
      expect(find.textContaining('APPROVED'), findsOneWidget);
      expect(find.text('No lines yet — pick a requisition above.'), findsOneWidget);

      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();

      expect(find.textContaining('Widget A'), findsWidgets);
      expect(find.textContaining('Req MREQ-001'), findsOneWidget);
      expect(find.text('10.00'), findsOneWidget);
      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.text('Approve'), findsNothing);
    });

    testWidgets('editing the issue qty and saving calls the repository with the updated payload', (tester) async {
      stubExistingDraft();
      when(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'MISS-001');
      when(() => mockRepo.cacheIssueLocally(
            effectiveIssueNo: any(named: 'effectiveIssueNo'),
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
          )).thenAnswer((_) async {});

      await pumpApp(
        tester,
        const MaterialIssueEntryScreen(editIssueNo: 'MISS-001', editIssueDate: '2026-07-01'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();

      await tester.enterText(find.text('10.00'), '6.00');
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
      expect(header['issue_no'], 'MISS-001');
      expect(lines, hasLength(1));
      expect(lines.first['product_id'], 'prod-001');
      expect(lines.first['source_requisition_no'], 'MREQ-001');
      expect(lines.first['department_id'], 'dept-001');
      expect(lines.first['consumption_area_id'], 'area-001');
      expect(lines.first['qty_pack'], 6.0);
      expect(lines.first['base_qty'], 6.0);

      expect(find.text('Material Issue MISS-001 saved.'), findsOneWidget);
    });
  });
}
