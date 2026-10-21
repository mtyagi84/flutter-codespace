import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/database/datasources/pos_batch_serial_local_ds.dart';
import 'package:sakal/features/sales/data/datasources/sales_invoice_local_ds.dart';
import 'package:sakal/features/sales/data/datasources/sales_invoice_remote_ds.dart';
import 'package:sakal/features/sales/data/repositories/sales_invoice_repository_impl.dart';
import 'package:sakal/features/sales/data/models/sales_invoice_header.dart';

class MockSalesInvoiceRemoteDs extends Mock implements SalesInvoiceRemoteDs {}

class MockSalesInvoiceLocalDs extends Mock implements SalesInvoiceLocalDs {}

class MockPosBatchSerialLocalDs extends Mock implements PosBatchSerialLocalDs {}

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

  late MockPosBatchSerialLocalDs batchSerialLocal;

  setUp(() {
    remote = MockSalesInvoiceRemoteDs();
    local = MockSalesInvoiceLocalDs();
    batchSerialLocal = MockPosBatchSerialLocalDs();
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

  // ── POS offline coverage, added 2026-10-21 ────────────────────────────
  // Native-build offline device testing for this session's two POS offline
  // features (Held Sales list, batch/serial-tracked sales) was blocked —
  // neither this machine nor the user has Windows admin rights to enable
  // Developer Mode (required for Flutter's Windows desktop build's plugin
  // symlinks), and no Android emulator is available either. This is the
  // next-best verification: proves the repository's own offline/online
  // routing logic is wired correctly, same proven pattern as the two
  // groups above. Does NOT prove the full on-device UX (Drift read/write,
  // SyncEngine queuing, a real network toggle) — that still needs an
  // actual native build once Developer Mode is available.
  group('listInvoices (Held Sales list offline fix)', () {
    const heldRow = SalesInvoiceHeader(
      invoiceNo: 'LOCAL-1', invoiceDate: '2026-10-21', saleType: 'CASH',
      customerName: '', partyName: 'Walk-in', status: 'DRAFT',
      grandTotal: 100, currencyId: 'INR', stockDispatchMode: 'IMMEDIATE',
    );

    test('offline: calls local, never touches remote', () async {
      when(() => local.listInvoices(
            clientId: any(named: 'clientId'), companyId: any(named: 'companyId'),
            search: any(named: 'search'), status: any(named: 'status'),
            saleType: any(named: 'saleType'), limit: any(named: 'limit'), offset: any(named: 'offset'),
          )).thenAnswer((_) async => [heldRow]);
      final repo = SalesInvoiceRepositoryImpl(remote, local, true);

      final result = await repo.listInvoices(clientId: 'c1', companyId: 'co1', status: 'DRAFT');

      expect(result, [heldRow]);
      verify(() => local.listInvoices(
            clientId: 'c1', companyId: 'co1', search: null, status: 'DRAFT',
            saleType: null, limit: 50, offset: 0,
          )).called(1);
      verifyNever(() => remote.listInvoices(
            clientId: any(named: 'clientId'), companyId: any(named: 'companyId'),
            search: any(named: 'search'), status: any(named: 'status'),
            saleType: any(named: 'saleType'), limit: any(named: 'limit'), offset: any(named: 'offset'),
          ));
    });

    test('online: calls remote, never touches local', () async {
      when(() => remote.listInvoices(
            clientId: any(named: 'clientId'), companyId: any(named: 'companyId'),
            search: any(named: 'search'), status: any(named: 'status'),
            saleType: any(named: 'saleType'), limit: any(named: 'limit'), offset: any(named: 'offset'),
          )).thenAnswer((_) async => [heldRow]);
      final repo = SalesInvoiceRepositoryImpl(remote, local, false);

      final result = await repo.listInvoices(clientId: 'c1', companyId: 'co1', status: 'DRAFT');

      expect(result, [heldRow]);
      verify(() => remote.listInvoices(
            clientId: 'c1', companyId: 'co1', search: null, status: 'DRAFT',
            saleType: null, limit: 50, offset: 0,
          )).called(1);
      verifyNever(() => local.listInvoices(
            clientId: any(named: 'clientId'), companyId: any(named: 'companyId'),
            search: any(named: 'search'), status: any(named: 'status'),
            saleType: any(named: 'saleType'), limit: any(named: 'limit'), offset: any(named: 'offset'),
          ));
    });
  });

  group('getBatchStockBalance / getSerialStockStatus (offline batch/serial sales)', () {
    test('offline: getBatchStockBalance calls the batch/serial local cache, never remote', () async {
      when(() => batchSerialLocal.getBatchStockBalance(
            clientId: any(named: 'clientId'), companyId: any(named: 'companyId'),
            locationId: any(named: 'locationId'), productId: any(named: 'productId'),
          )).thenAnswer((_) async => [
            {'batch_no': 'B1', 'expiry_date': '2027-01-01', 'balance': 10.0},
          ]);
      final repo = SalesInvoiceRepositoryImpl(remote, local, true, batchSerialLocal);

      final result = await repo.getBatchStockBalance(clientId: 'c1', companyId: 'co1', locationId: 'l1', productId: 'p1');

      expect(result, [{'batch_no': 'B1', 'expiry_date': '2027-01-01', 'balance': 10.0}]);
      verify(() => batchSerialLocal.getBatchStockBalance(clientId: 'c1', companyId: 'co1', locationId: 'l1', productId: 'p1')).called(1);
      verifyNever(() => remote.getBatchStockBalance(
            clientId: any(named: 'clientId'), companyId: any(named: 'companyId'),
            locationId: any(named: 'locationId'), productId: any(named: 'productId'),
          ));
    });

    test('online: getBatchStockBalance calls remote, never the local cache', () async {
      when(() => remote.getBatchStockBalance(
            clientId: any(named: 'clientId'), companyId: any(named: 'companyId'),
            locationId: any(named: 'locationId'), productId: any(named: 'productId'),
          )).thenAnswer((_) async => [
            {'batch_no': 'B1', 'expiry_date': '2027-01-01', 'balance': 10.0},
          ]);
      final repo = SalesInvoiceRepositoryImpl(remote, local, false, batchSerialLocal);

      final result = await repo.getBatchStockBalance(clientId: 'c1', companyId: 'co1', locationId: 'l1', productId: 'p1');

      expect(result, [{'batch_no': 'B1', 'expiry_date': '2027-01-01', 'balance': 10.0}]);
      verify(() => remote.getBatchStockBalance(clientId: 'c1', companyId: 'co1', locationId: 'l1', productId: 'p1')).called(1);
      verifyNever(() => batchSerialLocal.getBatchStockBalance(
            clientId: any(named: 'clientId'), companyId: any(named: 'companyId'),
            locationId: any(named: 'locationId'), productId: any(named: 'productId'),
          ));
    });

    test('offline: getSerialStockStatus calls the batch/serial local cache, never remote', () async {
      when(() => batchSerialLocal.getSerialStockStatus(
            clientId: any(named: 'clientId'), companyId: any(named: 'companyId'),
            locationId: any(named: 'locationId'), productId: any(named: 'productId'),
          )).thenAnswer((_) async => [
            {'serial_no': 'SN1', 'status': 'IN_STOCK'},
          ]);
      final repo = SalesInvoiceRepositoryImpl(remote, local, true, batchSerialLocal);

      final result = await repo.getSerialStockStatus(clientId: 'c1', companyId: 'co1', locationId: 'l1', productId: 'p1');

      expect(result, [{'serial_no': 'SN1', 'status': 'IN_STOCK'}]);
      verify(() => batchSerialLocal.getSerialStockStatus(clientId: 'c1', companyId: 'co1', locationId: 'l1', productId: 'p1')).called(1);
      verifyNever(() => remote.getSerialStockStatus(
            clientId: any(named: 'clientId'), companyId: any(named: 'companyId'),
            locationId: any(named: 'locationId'), productId: any(named: 'productId'),
          ));
    });

    test('offline with no batch/serial local cache available (web, _batchSerialLocal null): falls back to remote', () async {
      when(() => remote.getSerialStockStatus(
            clientId: any(named: 'clientId'), companyId: any(named: 'companyId'),
            locationId: any(named: 'locationId'), productId: any(named: 'productId'),
          )).thenAnswer((_) async => [
            {'serial_no': 'SN1', 'status': 'IN_STOCK'},
          ]);
      // No 4th constructor arg — mirrors how the provider constructs this
      // repository on Flutter Web, where PosBatchSerialLocalDs is null.
      final repo = SalesInvoiceRepositoryImpl(remote, local, true);

      final result = await repo.getSerialStockStatus(clientId: 'c1', companyId: 'co1', locationId: 'l1', productId: 'p1');

      expect(result, [{'serial_no': 'SN1', 'status': 'IN_STOCK'}]);
      verify(() => remote.getSerialStockStatus(clientId: 'c1', companyId: 'co1', locationId: 'l1', productId: 'p1')).called(1);
    });
  });
}
