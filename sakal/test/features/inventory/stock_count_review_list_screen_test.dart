import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/features/inventory/data/models/stock_count_review_model.dart';
import 'package:sakal/features/inventory/domain/repositories/stock_count_review_repository.dart';
import 'package:sakal/features/inventory/presentation/providers/stock_count_review_providers.dart';
import 'package:sakal/features/inventory/presentation/screens/stock_count_review_list_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockStockCountReviewRepository extends Mock implements StockCountReviewRepository {}

void main() {
  late MockStockCountReviewRepository mockRepo;

  setUp(() {
    mockRepo = MockStockCountReviewRepository();
  });

  // Unlike the other 8 Inventory list screens, this screen's own _load()
  // is a plain single `await` — no Future.wait, no
  // syncEngineProvider.pendingDocumentIds() call, and no _pendingIds field
  // at all — confirmed by reading the screen source (Stock Count Review is
  // documented app-wide as deliberately online-only: it needs a live view
  // of other counters' SUBMITTED status). So no syncEngineProvider override
  // is needed/used here — including one would just be dead code.
  List<Override> overrides() => [
        stockCountReviewRepositoryProvider.overrideWithValue(mockRepo),
      ];

  testWidgets('shows a loading indicator before the first page resolves', (tester) async {
    when(() => mockRepo.listReviews(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) => Completer<List<StockCountReviewHeader>>().future);

    await pumpApp(tester, const StockCountReviewListScreen(), overrides: overrides(), session: testSession());
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders a card per review once the page loads', (tester) async {
    when(() => mockRepo.listReviews(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => [
          StockCountReviewHeader.fromJson(const {
            'review_no': 'CNTR-001',
            'review_date': '2026-07-17',
            'location_id': 'loc-001',
            'location': {'location_name': 'Main Store'},
            'posted_adjustment_no': 'ADJ-050',
            'status': 'APPROVED',
          }),
          StockCountReviewHeader.fromJson(const {
            'review_no': 'CNTR-002',
            'review_date': '2026-07-18',
            'location_id': 'loc-002',
            'status': 'DRAFT',
          }),
        ]);

    await pumpApp(tester, const StockCountReviewListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('CNTR-001'), findsOneWidget);
    expect(find.text('CNTR-002'), findsOneWidget);
    expect(find.text('17 Jul 2026'), findsOneWidget);
    expect(find.text('18 Jul 2026'), findsOneWidget);
    expect(find.text('Main Store'), findsOneWidget);
    // Second review has an empty locationName — rendered as an em-dash.
    expect(find.text('—'), findsOneWidget);
    // Posted adjustment line only renders when postedAdjustmentNo is set.
    expect(find.text('Adjustment: ADJ-050'), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);
    expect(find.text('Approved'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows the empty state when the page loads with zero reviews', (tester) async {
    when(() => mockRepo.listReviews(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => []);

    await pumpApp(tester, const StockCountReviewListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('No stock count reviews found'), findsOneWidget);
  });

  testWidgets('shows the interpolated error message when the repository throws', (tester) async {
    when(() => mockRepo.listReviews(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenThrow(Exception('connection refused'));

    await pumpApp(tester, const StockCountReviewListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    // This screen's own _load() catch block interpolates the raw exception
    // directly (`'Could not load stock count reviews: $e'`) — no
    // ErrorPresenter.
    expect(find.text('Could not load stock count reviews: Exception: connection refused'), findsOneWidget);
  });
}
