import 'package:drift/drift.dart';

/// Offline cache for Stock Count (Screen 1 only — Screen 2/Review is
/// online-only, see project docs). Business composite key
/// (client_id, company_id, count_no, count_date).
@DataClassName('StockCountHeaderCacheEntry')
class StockCountHeadersCache extends Table {
  TextColumn get clientId          => text()();
  TextColumn get companyId         => text()();
  TextColumn get locationId        => text().withDefault(const Constant(''))();
  TextColumn get locationName      => text().withDefault(const Constant(''))();
  TextColumn get countNo           => text()();
  TextColumn get countDate         => text()(); // 'YYYY-MM-DD'
  TextColumn get categoryFilterId  => text().withDefault(const Constant(''))();
  TextColumn get natureFilter      => text().withDefault(const Constant(''))();
  TextColumn get remarks           => text().withDefault(const Constant(''))();
  TextColumn get status            => text().withDefault(const Constant('DRAFT'))();
  BoolColumn get isDeleted         => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt      => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, countNo, countDate};
}

/// rid_stock_count_lines — one row per PRODUCT in scope, not per lot.
/// batchesJson/serialsJson embed that line's rid_transaction_line_batches/
/// serials children as a JSON array directly on the row, same pragmatic
/// simplification every other cache table in this schema uses.
@DataClassName('StockCountLineCacheEntry')
class StockCountLinesCache extends Table {
  TextColumn get clientId            => text()();
  TextColumn get companyId           => text()();
  TextColumn get countNo             => text()();
  TextColumn get countDate           => text()();
  IntColumn  get serialNo            => integer()();
  TextColumn get productId           => text()();
  TextColumn get productCode         => text().withDefault(const Constant(''))();
  TextColumn get productName         => text().withDefault(const Constant(''))();
  TextColumn get trackingType        => text().withDefault(const Constant('NONE'))();
  TextColumn get uomId               => text().withDefault(const Constant(''))();
  TextColumn get uomLabel            => text().withDefault(const Constant(''))();
  RealColumn get uomConversionFactor => real().withDefault(const Constant(1.0))();
  TextColumn get productBarcode      => text().withDefault(const Constant(''))(); // catalog barcode — scan-match key only
  TextColumn get productPartNumber   => text().withDefault(const Constant(''))(); // catalog part number — scan-match key only
  BoolColumn get isCounted           => boolean().withDefault(const Constant(false))();
  RealColumn get countedQtyPack      => real().nullable()();
  RealColumn get countedQtyLoose     => real().nullable()();
  RealColumn get countedBaseQty      => real().nullable()();
  TextColumn get barcode             => text().withDefault(const Constant(''))();
  TextColumn get remarks             => text().withDefault(const Constant(''))();
  TextColumn get batchesJson         => text().withDefault(const Constant('[]'))();
  TextColumn get serialsJson         => text().withDefault(const Constant('[]'))();
  BoolColumn get isDeleted           => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt        => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, countNo, countDate, serialNo};
}
