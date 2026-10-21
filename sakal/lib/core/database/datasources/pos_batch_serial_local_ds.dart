import 'package:drift/drift.dart';
import '../app_database.dart';

/// Local datasource for [BatchStockBalanceCache]/[SerialStockStatusCache] —
/// the offline snapshot of `v_batch_stock_balance`/`v_serial_stock_status`
/// that lets a batch/serial-tracked product be sold while offline. Return
/// shapes mirror the remote datasource's own (`getBatchStockBalance`/
/// `getSerialStockStatus` in sales_invoice_remote_ds.dart) field-for-field,
/// so pos_new_sale_screen.dart's `_loadCandidates()` needs no change to
/// consume either source.
class PosBatchSerialLocalDs {
  final AppDatabase _db;
  PosBatchSerialLocalDs(this._db);

  Future<List<Map<String, dynamic>>> getBatchStockBalance({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) async {
    final rows = await (_db.select(_db.batchStockBalanceCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.locationId.equals(locationId))
          ..where((t) => t.productId.equals(productId))
          ..where((t) => t.availableBalance.isBiggerThanValue(0))
          ..orderBy([(t) => OrderingTerm.asc(t.expiryDate)]))
        .get();
    return rows.map((e) => {
          'batch_no': e.batchNo,
          'expiry_date': e.expiryDate,
          'balance': e.availableBalance,
        }).toList();
  }

  Future<List<Map<String, dynamic>>> getSerialStockStatus({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) async {
    final rows = await (_db.select(_db.serialStockStatusCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.locationId.equals(locationId))
          ..where((t) => t.productId.equals(productId))
          ..where((t) => t.status.equals('IN_STOCK'))
          ..orderBy([(t) => OrderingTerm.asc(t.serialNo)]))
        .get();
    return rows.map((e) => {'serial_no': e.serialNo, 'status': e.status}).toList();
  }

  Future<void> upsertBatches(List<Map<String, dynamic>> rows) async {
    await _db.batch((batch) {
      for (final r in rows) {
        batch.insert(
          _db.batchStockBalanceCache,
          BatchStockBalanceCacheCompanion.insert(
            clientId: r['client_id'] as String,
            companyId: r['company_id'] as String,
            locationId: r['location_id'] as String,
            productId: r['product_id'] as String,
            batchNo: r['batch_no'] as String,
            expiryDate: Value(r['expiry_date'] as String?),
            availableBalance: Value((r['balance'] as num?)?.toDouble() ?? 0),
            cachedAt: Value(DateTime.now()),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  Future<void> upsertSerials(List<Map<String, dynamic>> rows) async {
    await _db.batch((batch) {
      for (final r in rows) {
        batch.insert(
          _db.serialStockStatusCache,
          SerialStockStatusCacheCompanion.insert(
            clientId: r['client_id'] as String,
            companyId: r['company_id'] as String,
            locationId: r['location_id'] as String,
            productId: r['product_id'] as String,
            serialNo: r['serial_no'] as String,
            status: Value(r['status'] as String? ?? 'IN_STOCK'),
            cachedAt: Value(DateTime.now()),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  /// Wipes and reseeds every row for one location — the sync module's own
  /// unit of work, since a stale "balance=5" row left behind after the real
  /// balance drops to 0 (e.g. sold out between syncs) would otherwise never
  /// get cleaned up by an upsert-only write path.
  Future<void> replaceForLocation({
    required String clientId,
    required String companyId,
    required String locationId,
    required List<Map<String, dynamic>> batchRows,
    required List<Map<String, dynamic>> serialRows,
  }) async {
    await _db.transaction(() async {
      await (_db.delete(_db.batchStockBalanceCache)
            ..where((t) => t.clientId.equals(clientId))
            ..where((t) => t.companyId.equals(companyId))
            ..where((t) => t.locationId.equals(locationId)))
          .go();
      await (_db.delete(_db.serialStockStatusCache)
            ..where((t) => t.clientId.equals(clientId))
            ..where((t) => t.companyId.equals(companyId))
            ..where((t) => t.locationId.equals(locationId)))
          .go();
      await upsertBatches(batchRows);
      await upsertSerials(serialRows);
    });
  }
}
