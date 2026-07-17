import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/features/sales/data/datasources/sales_invoice_local_ds.dart';
import 'package:sakal/features/sales/data/datasources/sales_invoice_remote_ds.dart';
import 'package:sakal/features/sales/data/repositories/sales_invoice_repository_impl.dart';

class MockSalesInvoiceRemoteDs extends Mock implements SalesInvoiceRemoteDs {}

class MockSalesInvoiceLocalDs extends Mock implements SalesInvoiceLocalDs {}

/// Verifies SalesInvoiceRepositoryImpl's offline/online branching is wired
/// correctly — the exact class of bug this whole Master-Data Sync facility
/// was built to fix (Quick Invoice throwing "Could not load data" offline
/// because these branches didn't exist at all). Covers two representative
/// methods (one with no write-through, one with write-through) rather than
/// all 9 — the pattern to copy for GRN/PO/etc.'s own new offline branches
/// if broader coverage is wanted later.
void main() {
  late MockSalesInvoiceRemoteDs remote;
  late MockSalesInvoiceLocalDs local;

  setUpAll(() {
    // Defensive — mocktail's built-in dummy values cover common types, but
    // registering explicitly avoids any doubt for the `row:` Map argument
    // matched with any() below, since this can't be run locally to confirm.
    registerFallbackValue(<String, dynamic>{});
  });

  setUp(() {
    remote = MockSalesInvoiceRemoteDs();
    local = MockSalesInvoiceLocalDs();
  });

  group('getProductsForPicker (no write-through — see repository comment)', () {
    test('offline: calls local, never touches remote', () async {
      when(() => local.getProductsForPicker(
            clientId: any(named: 'clientId'), companyId: any(named: 'companyId'), search: any(named: 'search'),
          )).thenAnswer((_) async => [
            {'id': 'p1', 'product_code': 'SI-001'},
          ]);
      final repo = SalesInvoiceRepositoryImpl(remote, local, true);

      final result = await repo.getProductsForPicker(clientId: 'c1', companyId: 'co1', search: 'SI');

      expect(result, [{'id': 'p1', 'product_code': 'SI-001'}]);
      verify(() => local.getProductsForPicker(clientId: 'c1', companyId: 'co1', search: 'SI')).called(1);
      verifyNever(() => remote.getProductsForPicker(
            clientId: any(named: 'clientId'), companyId: any(named: 'companyId'), search: any(named: 'search'),
          ));
    });

    test('online: calls remote, never touches local', () async {
      when(() => remote.getProductsForPicker(
            clientId: any(named: 'clientId'), companyId: any(named: 'companyId'), search: any(named: 'search'),
          )).thenAnswer((_) async => [
            {'id': 'p1', 'product_code': 'SI-001'},
          ]);
      final repo = SalesInvoiceRepositoryImpl(remote, local, false);

      final result = await repo.getProductsForPicker(clientId: 'c1', companyId: 'co1');

      expect(result, [{'id': 'p1', 'product_code': 'SI-001'}]);
      verify(() => remote.getProductsForPicker(clientId: 'c1', companyId: 'co1', search: null)).called(1);
      verifyNever(() => local.getProductsForPicker(
            clientId: any(named: 'clientId'), companyId: any(named: 'companyId'), search: any(named: 'search'),
          ));
    });
  });

  group('getQuickInvoiceSetup (has write-through)', () {
    test('offline: calls local only — this is the exact bug that made Quick Invoice unusable offline', () async {
      when(() => local.getQuickInvoiceSetup(
            clientId: any(named: 'clientId'), companyId: any(named: 'companyId'), userId: any(named: 'userId'),
          )).thenAnswer((_) async => {'location_id': 'loc1', 'cash_customer_id': 'cust1'});
      final repo = SalesInvoiceRepositoryImpl(remote, local, true);

      final result = await repo.getQuickInvoiceSetup(clientId: 'c1', companyId: 'co1', userId: 'u1');

      expect(result?['location_id'], 'loc1');
      verify(() => local.getQuickInvoiceSetup(clientId: 'c1', companyId: 'co1', userId: 'u1')).called(1);
      verifyNever(() => remote.getQuickInvoiceSetup(
            clientId: any(named: 'clientId'), companyId: any(named: 'companyId'), userId: any(named: 'userId'),
          ));
    });

    test('online: calls remote and writes through to the local cache exactly once', () async {
      when(() => remote.getQuickInvoiceSetup(
            clientId: any(named: 'clientId'), companyId: any(named: 'companyId'), userId: any(named: 'userId'),
          )).thenAnswer((_) async => {'location_id': 'loc1', 'cash_customer_id': 'cust1'});
      when(() => local.cacheQuickInvoiceSetup(
            clientId: any(named: 'clientId'), companyId: any(named: 'companyId'), userId: any(named: 'userId'),
            row: any(named: 'row'),
          )).thenAnswer((_) async {});
      final repo = SalesInvoiceRepositoryImpl(remote, local, false);

      final result = await repo.getQuickInvoiceSetup(clientId: 'c1', companyId: 'co1', userId: 'u1');

      expect(result?['location_id'], 'loc1');
      verify(() => remote.getQuickInvoiceSetup(clientId: 'c1', companyId: 'co1', userId: 'u1')).called(1);
      verify(() => local.cacheQuickInvoiceSetup(
            clientId: 'c1', companyId: 'co1', userId: 'u1', row: {'location_id': 'loc1', 'cash_customer_id': 'cust1'},
          )).called(1);
    });

    test('online: a null result (no Quick Invoice Setup row) is never cached', () async {
      when(() => remote.getQuickInvoiceSetup(
            clientId: any(named: 'clientId'), companyId: any(named: 'companyId'), userId: any(named: 'userId'),
          )).thenAnswer((_) async => null);
      final repo = SalesInvoiceRepositoryImpl(remote, local, false);

      final result = await repo.getQuickInvoiceSetup(clientId: 'c1', companyId: 'co1', userId: 'u1');

      expect(result, isNull);
      verifyNever(() => local.cacheQuickInvoiceSetup(
            clientId: any(named: 'clientId'), companyId: any(named: 'companyId'), userId: any(named: 'userId'),
            row: any(named: 'row'),
          ));
    });
  });
}
