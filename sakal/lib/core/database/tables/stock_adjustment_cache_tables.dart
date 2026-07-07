import 'package:drift/drift.dart';

/// Offline cache for Stock Adjustments. Business composite key
/// (client_id, company_id, adjustment_no, adjustment_date).
@DataClassName('StockAdjustmentHeaderCacheEntry')
class StockAdjustmentHeadersCache extends Table {
  TextColumn get clientId       => text()();
  TextColumn get companyId      => text()();
  TextColumn get locationId     => text().withDefault(const Constant(''))();
  TextColumn get locationName   => text().withDefault(const Constant(''))();
  TextColumn get adjustmentNo   => text()();
  TextColumn get adjustmentDate => text()(); // 'YYYY-MM-DD'
  TextColumn get reasonId       => text().withDefault(const Constant(''))();
  TextColumn get reasonLabel    => text().withDefault(const Constant(''))();
  TextColumn get remarks        => text().withDefault(const Constant(''))();
  TextColumn get status         => text().withDefault(const Constant('DRAFT'))();
  BoolColumn get isDeleted      => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt   => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, adjustmentNo, adjustmentDate};
}

/// rid_stock_adjustment_lines. batchesJson/serialsJson embed that line's
/// rid_transaction_line_batches/serials children as a JSON array directly on
/// the row — same pragmatic simplification every other cache table in this
/// schema uses. Direction (adjust_flag) lives on the line itself; the
/// batch/serial rows don't need their own sign, same as the backend.
@DataClassName('StockAdjustmentLineCacheEntry')
class StockAdjustmentLinesCache extends Table {
  TextColumn get clientId            => text()();
  TextColumn get companyId           => text()();
  TextColumn get adjustmentNo        => text()();
  TextColumn get adjustmentDate      => text()();
  IntColumn  get serialNo            => integer()();
  TextColumn get productId           => text()();
  TextColumn get productCode        => text().withDefault(const Constant(''))();
  TextColumn get productName        => text().withDefault(const Constant(''))();
  TextColumn get trackingType       => text().withDefault(const Constant('NONE'))();
  TextColumn get uomId               => text().withDefault(const Constant(''))();
  TextColumn get uomLabel            => text().withDefault(const Constant(''))();
  RealColumn get uomConversionFactor => real().withDefault(const Constant(1.0))();
  RealColumn get qtyPack             => real().withDefault(const Constant(0.0))();
  RealColumn get qtyLoose            => real().withDefault(const Constant(0.0))();
  RealColumn get baseQty             => real().withDefault(const Constant(0.0))();
  TextColumn get adjustFlag          => text()(); // '+' or '-'
  RealColumn get systemQty           => real().nullable()();
  RealColumn get unitCost            => real().nullable()();
  RealColumn get unitCostSpecific    => real().nullable()();
  TextColumn get barcode             => text().withDefault(const Constant(''))();
  TextColumn get reasonId            => text().withDefault(const Constant(''))();
  TextColumn get reasonLabel         => text().withDefault(const Constant(''))();
  TextColumn get remarks             => text().withDefault(const Constant(''))();
  TextColumn get batchesJson         => text().withDefault(const Constant('[]'))();
  TextColumn get serialsJson         => text().withDefault(const Constant('[]'))();
  BoolColumn get isDeleted           => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt        => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, adjustmentNo, adjustmentDate, serialNo};
}
