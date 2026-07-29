import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/providers/master_cache_providers.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/features/sales/data/models/price_master_header.dart';
import 'package:sakal/features/sales/domain/repositories/price_master_repository.dart';
import 'package:sakal/features/sales/presentation/providers/price_master_providers.dart';
import 'package:sakal/features/sales/presentation/screens/price_master_list_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockPriceMasterRepository extends Mock implements PriceMasterRepository {}

void main() {
  late MockPriceMasterRepository mockRepo;

  setUp(() {
    mockRepo = MockPriceMasterRepository();
  });

  // This screen's own _load() also Future.waits on `locationsProvider`
  // (core/providers/master_cache_providers.dart, a plain FutureProvider) to
  // populate its Location filter dropdown — that has to be overridden too,
  // or the real provider chain runs and hits a real datasource.
  List<Override> overrides() => [
        priceMasterRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
        locationsProvider.overrideWith((ref) async => <Map<String, dynamic>>[]),
      ];

  testWidgets('shows a loading indicator before the first page resolves', (tester) async {
    when(() => mockRepo.listBatches(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          priceType: any(named: 'priceType'),
          locationId: any(named: 'locationId'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) => Completer<List<PriceMasterHeader>>().future);

    await pumpApp(tester, const PriceMasterListScreen(), overrides: overrides(), session: testSession());
    await tester.pump(); // let initState's postFrameCallback fire and _load() start

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders a card per batch once the page loads', (tester) async {
    when(() => mockRepo.listBatches(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          priceType: any(named: 'priceType'),
          locationId: any(named: 'locationId'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => [
          PriceMasterHeader.fromJson(const {
            'entry_no': 'PM-001',
            'entry_date': '2026-07-01',
            'location': {'location_name': 'Main Warehouse'},
            'price_type': 'GENERIC',
            'effective_date': '2026-07-05',
            'currency': {'currency_id': 'USD'},
            'status': 'DRAFT',
            'line_count': 3,
          }),
          PriceMasterHeader.fromJson(const {
            'entry_no': 'PM-002',
            'entry_date': '2026-07-02',
            'location': {'location_name': 'Branch B'},
            'price_type': 'CUSTOMER',
            'customer': {'account_code': 'CUST05', 'account_name': 'Epsilon Inc'},
            'effective_date': '2026-07-10',
            'currency': {'currency_id': 'ZMW'},
            'status': 'APPROVED',
            'line_count': 0,
          }),
        ]);

    await pumpApp(tester, const PriceMasterListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('PM-001'), findsOneWidget);
    expect(find.text('PM-002'), findsOneWidget);
    expect(find.text('Generic'), findsOneWidget);
    expect(find.text('Customer'), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);
    expect(find.text('Approved'), findsOneWidget);
    expect(find.text('Main Warehouse  ·  USD'), findsOneWidget);
    expect(find.text('Branch B  ·  ZMW'), findsOneWidget);
    expect(find.text('Generic (all customers)'), findsOneWidget);
    expect(find.text('[CUST05] Epsilon Inc'), findsOneWidget);
    expect(find.text('01 Jul 2026 · Effective 05 Jul 2026'), findsOneWidget);
    expect(find.text('02 Jul 2026 · Effective 10 Jul 2026'), findsOneWidget);
    expect(find.text('3 line(s)'), findsOneWidget);
    expect(find.text('0 line(s)'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows the empty state when the page loads with zero batches', (tester) async {
    when(() => mockRepo.listBatches(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          priceType: any(named: 'priceType'),
          locationId: any(named: 'locationId'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => []);

    await pumpApp(tester, const PriceMasterListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('No price batches found'), findsOneWidget);
  });

  testWidgets('shows a friendly error message (never the raw exception) when the repository throws', (tester) async {
    when(() => mockRepo.listBatches(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          status: any(named: 'status'),
          priceType: any(named: 'priceType'),
          locationId: any(named: 'locationId'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenThrow(Exception('connection refused'));

    await pumpApp(tester, const PriceMasterListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('Unable to load price batches. Please try again.'), findsOneWidget);
    expect(find.textContaining('connection refused'), findsNothing);
  });
}
