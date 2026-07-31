import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/features/inventory/domain/repositories/stock_count_review_repository.dart';
import 'package:sakal/features/inventory/presentation/providers/stock_count_review_providers.dart';
import 'package:sakal/features/inventory/presentation/screens/stock_count_review_entry_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockStockCountReviewRepository extends Mock implements StockCountReviewRepository {}

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
  late MockStockCountReviewRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
  });

  setUp(() {
    mockRepo = MockStockCountReviewRepository();
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
    when(() => mockRepo.getSubmittedCounts(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          locationId: any(named: 'locationId'),
          currentReviewNo: any(named: 'currentReviewNo'),
        )).thenAnswer((_) async => []);
  });

  List<Override> overrides() => [
        stockCountReviewRepositoryProvider.overrideWithValue(mockRepo),
      ];

  group('New (blank) review — nothing selected yet', () {
    testWidgets('renders the blank form, empty source-picker/variance panels, and only Save Draft', (tester) async {
      await pumpApp(tester, const StockCountReviewEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      expect(find.text('New Stock Count Review'), findsOneWidget);
      expect(find.text('Unsaved draft'), findsOneWidget);
      expect(_findFieldLabel('Review No'), findsOneWidget);
      expect(_findFieldLabel('Store / Location'), findsOneWidget);
      expect(_findFieldLabel('Review Date'), findsOneWidget);
      expect(_findFieldLabel('As Of Date *'), findsOneWidget);
      expect(_findFieldLabel('Reason'), findsOneWidget);
      expect(_findFieldLabel('Remarks'), findsOneWidget);

      expect(find.text('No submitted counts available at this location yet.'), findsOneWidget);
      expect(find.text('Select at least one submitted Stock Count to see variance.'), findsOneWidget);

      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.text('Approve'), findsNothing);
      expect(find.byIcon(Icons.print_outlined), findsNothing);
    });

    testWidgets('blocks Save Draft and shows a validation message when no source count is selected', (tester) async {
      await pumpApp(tester, const StockCountReviewEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      expect(find.text('Select at least one submitted Stock Count.'), findsOneWidget);
      verifyNever(() => mockRepo.save(
            header: any(named: 'header'),
            sourceRefs: any(named: 'sourceRefs'),
            userId: any(named: 'userId'),
          ));
    });
  });

  group('Resuming an existing DRAFT review — clubbed source counts + variance preview', () {
    void stubExistingDraft() {
      when(() => mockRepo.getHeader(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            reviewNo: any(named: 'reviewNo'),
            reviewDate: any(named: 'reviewDate'),
          )).thenAnswer((_) async => {
            'review_no': 'REV-001',
            'review_date': '2026-07-01',
            'as_of_date': '2026-07-01',
            'status': 'DRAFT',
            'location_id': 'loc-001',
            'reason_id': 'reason-001',
            'remarks': 'Original remarks',
            'posted_adjustment_no': null,
          });
      when(() => mockRepo.getSources(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            reviewNo: any(named: 'reviewNo'),
            reviewDate: any(named: 'reviewDate'),
          )).thenAnswer((_) async => [
            {'source_count_no': 'CNT-001', 'source_count_date': '2026-07-01'},
          ]);
      when(() => mockRepo.getSubmittedCounts(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            locationId: any(named: 'locationId'),
            currentReviewNo: any(named: 'currentReviewNo'),
          )).thenAnswer((_) async => [
            {'count_no': 'CNT-001', 'count_date': '2026-07-01', 'remarks': 'Blind count remarks'},
          ]);
      when(() => mockRepo.computeVariance(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            reviewNo: any(named: 'reviewNo'),
            reviewDate: any(named: 'reviewDate'),
          )).thenAnswer((_) async => [
            {
              'product_id': 'prod-001',
              'product_code': 'WID-A',
              'product_name': 'Widget A',
              'batch_no': null,
              'serial_no': null,
              'counted_qty': 10,
              'system_qty': 8,
              'variance_qty': 2,
              'adjust_flag': '+',
              'is_unknown_serial': false,
            },
          ]);
    }

    testWidgets('loads the saved header, the already-selected source count, and the computed variance grid', (tester) async {
      stubExistingDraft();

      await pumpApp(
        tester,
        const StockCountReviewEntryScreen(editReviewNo: 'REV-001', editReviewDate: '2026-07-01'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.text('Stock Count Review · REV-001'), findsOneWidget);
      expect(find.text('Draft'), findsOneWidget);
      expect(find.text('Main Warehouse'), findsOneWidget);
      expect(find.text('Physical Count Variance'), findsOneWidget);
      expect(find.text('Original remarks'), findsOneWidget);

      // The source count that built this review is pre-selected (checked).
      expect(find.text('CNT-001'), findsOneWidget);
      final tile = tester.widget<CheckboxListTile>(find.byType(CheckboxListTile).first);
      expect(tile.value, true);

      // Variance grid — counted vs system vs variance, never a blind count.
      expect(find.text('PRODUCT'), findsOneWidget);
      expect(find.text('COUNTED'), findsOneWidget);
      expect(find.text('SYSTEM'), findsOneWidget);
      expect(find.text('VARIANCE'), findsOneWidget);
      expect(find.textContaining('Widget A'), findsWidgets);
      expect(find.text('10.00'), findsOneWidget);
      expect(find.text('8.00'), findsOneWidget);
      expect(find.text('+2.00'), findsOneWidget);

      expect(find.text('Save Draft'), findsOneWidget);
      // canApprove defaults false with an empty menuProvider — Approve stays hidden.
      expect(find.text('Approve'), findsNothing);
    });

    testWidgets('selecting another submitted count re-saves the review with the updated source list', (tester) async {
      // Start from a blank (new) review — no editReviewNo — but with one
      // submitted count already available to pick, mirroring how a manager
      // actually builds a review: tick a count, which itself triggers a
      // Save (there is no separate free-text field to edit on this screen).
      when(() => mockRepo.getSubmittedCounts(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            locationId: any(named: 'locationId'),
            currentReviewNo: any(named: 'currentReviewNo'),
          )).thenAnswer((_) async => [
            {'count_no': 'CNT-002', 'count_date': '2026-07-05', 'remarks': ''},
          ]);
      when(() => mockRepo.save(
            header: any(named: 'header'),
            sourceRefs: any(named: 'sourceRefs'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'REV-002');
      when(() => mockRepo.computeVariance(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            reviewNo: any(named: 'reviewNo'),
            reviewDate: any(named: 'reviewDate'),
          )).thenAnswer((_) async => []);

      await pumpApp(tester, const StockCountReviewEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.text('CNT-002'), findsOneWidget);
      await tester.tap(find.byType(CheckboxListTile).first);
      await _pumpBriefly(tester);

      final captured = verify(() => mockRepo.save(
            header: captureAny(named: 'header'),
            sourceRefs: captureAny(named: 'sourceRefs'),
            userId: any(named: 'userId'),
          )).captured;
      final header = captured[0] as Map<String, dynamic>;
      final sourceRefs = captured[1] as List<Map<String, dynamic>>;

      expect(header['location_id'], 'loc-001');
      expect(header['reason_id'], 'reason-001');
      expect(sourceRefs, hasLength(1));
      expect(sourceRefs.first['source_count_no'], 'CNT-002');
      expect(sourceRefs.first['source_count_date'], '2026-07-05');
    });
  });
}
