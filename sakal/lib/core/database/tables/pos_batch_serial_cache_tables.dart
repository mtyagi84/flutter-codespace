import 'package:drift/drift.dart';

/// Local snapshot of `v_batch_stock_balance`/`v_serial_stock_status`
/// (migrations 060/063) — the ONLY thing standing between a batch/serial-
/// tracked product and offline POS sale support (pos_new_sale_screen.dart's
/// `_charge()`/`_hold()` both hard-block a tracked line while offline since
/// neither candidate lookup had any local fallback until this table).
///
/// A snapshot, not a source of truth — correctness at sync time is still
/// guaranteed by `fn_post_stock_movement`'s own existing strict batch/
/// serial negative-stock check (batch/serial can NEVER go negative,
/// regardless of `allow_negative_stock` flags), not by this cache being
/// perfectly fresh. A stale allocation simply fails loudly at sync
/// (`BATCH_INSUFFICIENT_STOCK`/`SERIAL_NOT_IN_STOCK`) and lands in Manager
/// Review's existing retry flow — same mechanism already covering the
/// ordinary online race-condition case, no new reconciliation UI needed.
@DataClassName('BatchStockBalanceCacheEntry')
class BatchStockBalanceCache extends Table {
  TextColumn get clientId          => text()();
  TextColumn get companyId         => text()();
  TextColumn get locationId        => text()();
  TextColumn get productId         => text()();
  TextColumn get batchNo           => text()();
  TextColumn get expiryDate        => text().nullable()(); // 'YYYY-MM-DD'
  RealColumn get availableBalance  => real().withDefault(const Constant(0))();
  DateTimeColumn get cachedAt      => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, locationId, productId, batchNo};
}

@DataClassName('SerialStockStatusCacheEntry')
class SerialStockStatusCache extends Table {
  TextColumn get clientId   => text()();
  TextColumn get companyId  => text()();
  TextColumn get locationId => text()();
  TextColumn get productId  => text()();
  TextColumn get serialNo   => text()();
  TextColumn get status     => text().withDefault(const Constant('IN_STOCK'))();
  DateTimeColumn get cachedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, locationId, productId, serialNo};
}
