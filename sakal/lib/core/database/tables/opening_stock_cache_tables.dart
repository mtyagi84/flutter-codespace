import 'package:drift/drift.dart';

/// Offline cache for Opening Stock. Business composite key
/// (client_id, company_id, opening_no, opening_date).
@DataClassName('OpeningStockHeaderCacheEntry')
class OpeningStockHeadersCache extends Table {
  TextColumn get clientId     => text()();
  TextColumn get companyId    => text()();
  TextColumn get locationId   => text().withDefault(const Constant(''))();
  TextColumn get locationName => text().withDefault(const Constant(''))();
  TextColumn get openingNo    => text()();
  TextColumn get openingDate  => text()(); // 'YYYY-MM-DD'
  TextColumn get remarks      => text().withDefault(const Constant(''))();
  TextColumn get status       => text().withDefault(const Constant('DRAFT'))();
  BoolColumn get isDeleted    => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, openingNo, openingDate};
}

/// rid_opening_stock_lines — one row per physical lot/unit, not per product.
/// batch_no/expiry_date/serial_no sit flat on the line, per the module's own
/// deliberate divergence from every other module's line+child-table shape.
@DataClassName('OpeningStockLineCacheEntry')
class OpeningStockLinesCache extends Table {
  TextColumn get clientId            => text()();
  TextColumn get companyId           => text()();
  TextColumn get openingNo           => text()();
  TextColumn get openingDate         => text()();
  IntColumn  get lineNo              => integer()();
  TextColumn get productId           => text()();
  TextColumn get productCode         => text().withDefault(const Constant(''))();
  TextColumn get productName         => text().withDefault(const Constant(''))();
  TextColumn get trackingType        => text().withDefault(const Constant('NONE'))();
  TextColumn get uomId               => text().withDefault(const Constant(''))();
  TextColumn get uomLabel            => text().withDefault(const Constant(''))();
  RealColumn get uomConversionFactor => real().withDefault(const Constant(1.0))();
  RealColumn get packQty             => real().withDefault(const Constant(0.0))();
  RealColumn get looseQty            => real().withDefault(const Constant(0.0))();
  RealColumn get baseQty             => real().withDefault(const Constant(0.0))();
  TextColumn get batchNo             => text().withDefault(const Constant(''))();
  TextColumn get expiryDate          => text().withDefault(const Constant(''))();
  TextColumn get manufacturingDate   => text().withDefault(const Constant(''))();
  TextColumn get serialNo            => text().withDefault(const Constant(''))();
  RealColumn get unitCost            => real().withDefault(const Constant(0.0))();
  RealColumn get unitCostSpecific    => real().nullable()();
  TextColumn get barcode             => text().withDefault(const Constant(''))();
  TextColumn get remarks             => text().withDefault(const Constant(''))();
  BoolColumn get isDeleted           => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt        => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, openingNo, openingDate, lineNo};
}
