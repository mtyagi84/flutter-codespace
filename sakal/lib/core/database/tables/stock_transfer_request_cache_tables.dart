import 'package:drift/drift.dart';

/// Offline cache for Stock Transfer Requests. Business composite key
/// (client_id, company_id, request_no, request_date).
@DataClassName('StockTransferRequestHeaderCacheEntry')
class StockTransferRequestHeadersCache extends Table {
  TextColumn get clientId         => text()();
  TextColumn get companyId        => text()();
  TextColumn get fromLocationId   => text().withDefault(const Constant(''))();
  TextColumn get fromLocationName => text().withDefault(const Constant(''))();
  TextColumn get toLocationId     => text().withDefault(const Constant(''))();
  TextColumn get toLocationName   => text().withDefault(const Constant(''))();
  TextColumn get requestNo        => text()();
  TextColumn get requestDate      => text()(); // 'YYYY-MM-DD'
  TextColumn get remarks          => text().withDefault(const Constant(''))();
  TextColumn get status           => text().withDefault(const Constant('DRAFT'))();
  BoolColumn get isDeleted        => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt     => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, requestNo, requestDate};
}

@DataClassName('StockTransferRequestLineCacheEntry')
class StockTransferRequestLinesCache extends Table {
  TextColumn get clientId             => text()();
  TextColumn get companyId            => text()();
  TextColumn get requestNo            => text()();
  TextColumn get requestDate          => text()();
  IntColumn  get serialNo             => integer()();
  TextColumn get productId            => text()();
  TextColumn get productCode          => text().withDefault(const Constant(''))();
  TextColumn get productName          => text().withDefault(const Constant(''))();
  TextColumn get uomId                => text().withDefault(const Constant(''))();
  TextColumn get uomLabel             => text().withDefault(const Constant(''))();
  RealColumn get uomConversionFactor  => real().withDefault(const Constant(1.0))();
  RealColumn get qtyPack              => real().withDefault(const Constant(0.0))();
  RealColumn get qtyLoose             => real().withDefault(const Constant(0.0))();
  RealColumn get baseQty              => real().withDefault(const Constant(0.0))();
  RealColumn get transferredQty       => real().withDefault(const Constant(0.0))();
  TextColumn get remarks              => text().withDefault(const Constant(''))();
  BoolColumn get isDeleted            => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt         => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, requestNo, requestDate, serialNo};
}
