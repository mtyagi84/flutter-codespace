import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/features/master/data/models/product_model.dart';
import 'package:sakal/features/master/domain/repositories/products_repository.dart';
import 'package:sakal/features/master/presentation/providers/products_providers.dart';
import 'package:sakal/features/master/presentation/screens/product_list_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockProductsRepository extends Mock implements ProductsRepository {}

void main() {
  late MockProductsRepository mockRepo;

  setUp(() {
    mockRepo = MockProductsRepository();
  });

  // Built fresh inside each test — see journal_voucher_list_screen_test.dart's
  // comment: mockRepo is only assigned once setUp() runs before each test, so
  // building this list at the top of main() throws LateError.
  //
  // product_list_screen.dart is one of the two screens in this app that had
  // hand-rolled pagination BEFORE PagedListController existed (see CLAUDE.md's
  // "Pagination" mandatory pattern) — it manages its own _offset/_pageSize/
  // _hasMore/_loadingMore fields directly rather than using that shared
  // utility, so there's no PagedListController involved here at all.
  //
  // Its error handling is also narrower than every other screen in this
  // batch: `on DioException catch (e)` ONLY — a plain Exception (like the
  // one every other test file in this batch throws) would propagate
  // uncaught instead of being shown as a friendly error, so the error test
  // below throws a DioException instead.
  List<Override> overrides() => [
        productsRepositoryProvider.overrideWithValue(mockRepo),
      ];

  testWidgets('shows a loading indicator before the first page resolves', (tester) async {
    when(() => mockRepo.getProducts(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          nature: any(named: 'nature'),
          isActive: any(named: 'isActive'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) => Completer<List<ProductModel>>().future);

    await pumpApp(tester, const ProductListScreen(), overrides: overrides(), session: testSession());
    await tester.pump(); // let initState's postFrameCallback fire and _load() start

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders a card per product once the page loads', (tester) async {
    when(() => mockRepo.getProducts(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          nature: any(named: 'nature'),
          isActive: any(named: 'isActive'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => [
          ProductModel.fromJson(const {
            'id': 'prod-1',
            'client_id': 'client-001',
            'company_id': 'company-001',
            'product_code': 'PRD-001',
            'product_name': 'Widget A',
            'product_nature': 'FINISHED_GOOD',
            'category': {'category_name': 'Widgets'},
            'is_active': true,
          }),
          ProductModel.fromJson(const {
            'id': 'prod-2',
            'client_id': 'client-001',
            'company_id': 'company-001',
            'product_code': 'PRD-002',
            'product_name': 'Widget B',
            'product_nature': 'SERVICE',
            'is_active': false,
          }),
        ]);

    await pumpApp(tester, const ProductListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('PRD-001'), findsOneWidget);
    expect(find.text('PRD-002'), findsOneWidget);
    expect(find.text('Widget A'), findsOneWidget);
    expect(find.text('Widget B'), findsOneWidget);
    expect(find.text('Finished Good'), findsOneWidget);
    expect(find.text('Service'), findsOneWidget);
    // Product 2 has no category embed — the card simply omits the category
    // line rather than showing a placeholder, so only one match is expected.
    expect(find.text('Widgets'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows the empty state when the page loads with zero products', (tester) async {
    when(() => mockRepo.getProducts(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          nature: any(named: 'nature'),
          isActive: any(named: 'isActive'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => []);

    await pumpApp(tester, const ProductListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    expect(find.text('No products yet.'), findsOneWidget);
  });

  testWidgets('shows an error message when the repository throws a DioException', (tester) async {
    when(() => mockRepo.getProducts(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
          search: any(named: 'search'),
          nature: any(named: 'nature'),
          isActive: any(named: 'isActive'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        )).thenThrow(DioException(requestOptions: RequestOptions(path: '/rim_products')));

    await pumpApp(tester, const ProductListScreen(), overrides: overrides(), session: testSession());
    await tester.pumpAndSettle();

    // No response body on this DioException, so the screen's own fallback
    // text is shown (see product_list_screen.dart's `on DioException` catch
    // block: `e.response?.data?['message'] as String? ?? 'Failed to load
    // products.'`).
    expect(find.text('Failed to load products.'), findsOneWidget);
  });
}
