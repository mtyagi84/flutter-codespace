import 'package:drift/drift.dart';

/// Offline cache for Stock Transfers. Business composite key
/// (client_id, company_id, transfer_no, transfer_date).
@DataClassName('StockTransferHeaderCacheEntry')
class StockTransferHeadersCache extends Table {
  TextColumn get clientId           => text()();
  TextColumn get companyId          => text()();
  TextColumn get fromLocationId     => text().withDefault(const Constant(''))();
  TextColumn get fromLocationName   => text().withDefault(const Constant(''))();
  TextColumn get toLocationId       => text().withDefault(const Constant(''))();
  TextColumn get toLocationName     => text().withDefault(const Constant(''))();
  TextColumn get transferNo         => text()();
  TextColumn get transferDate       => text()(); // 'YYYY-MM-DD'
  BoolColumn get againstRequest     => boolean().withDefault(const Constant(false))();
  TextColumn get sourceRequestNo    => text().withDefault(const Constant(''))();
  TextColumn get sourceRequestDate  => text().withDefault(const Constant(''))();
  TextColumn get remarks            => text().withDefault(const Constant(''))();
  RealColumn get chargesAmount      => real().withDefault(const Constant(0.0))();
  TextColumn get status             => text().withDefault(const Constant('DRAFT'))();
  TextColumn get postingMode        => text().withDefault(const Constant(''))();
  BoolColumn get isDeleted          => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt       => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, transferNo, transferDate};
}

/// rid_stock_transfer_lines. batchesJson/serialsJson embed that line's
/// batch/serial allocation the same way GrnLinesCache does.
@DataClassName('StockTransferLineCacheEntry')
class StockTransferLinesCache extends Table {
  TextColumn get clientId                  => text()();
  TextColumn get companyId                 => text()();
  TextColumn get transferNo                => text()();
  TextColumn get transferDate              => text()();
  IntColumn  get serialNo                  => integer()();
  TextColumn get sourceRequestNo           => text().withDefault(const Constant(''))();
  TextColumn get sourceRequestDate         => text().withDefault(const Constant(''))();
  IntColumn  get sourceRequestLineSerial   => integer().nullable()();
  TextColumn get productId                 => text()();
  TextColumn get productCode                => text().withDefault(const Constant(''))();
  TextColumn get productName                => text().withDefault(const Constant(''))();
  TextColumn get uomId                       => text().withDefault(const Constant(''))();
  TextColumn get uomLabel                    => text().withDefault(const Constant(''))();
  RealColumn get uomConversionFactor         => real().withDefault(const Constant(1.0))();
  RealColumn get qtyPack                     => real().withDefault(const Constant(0.0))();
  RealColumn get qtyLoose                    => real().withDefault(const Constant(0.0))();
  RealColumn get baseQty                     => real().withDefault(const Constant(0.0))();
  RealColumn get costPrice                   => real().withDefault(const Constant(0.0))();
  RealColumn get salesPrice                  => real().nullable()();
  RealColumn get chargeAmount                => real().withDefault(const Constant(0.0))();
  TextColumn get remarks                     => text().withDefault(const Constant(''))();
  TextColumn get batchesJson                 => text().withDefault(const Constant('[]'))();
  TextColumn get serialsJson                 => text().withDefault(const Constant('[]'))();
  BoolColumn get isDeleted                   => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt                => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, transferNo, transferDate, serialNo};
}

@DataClassName('StockTransferChargeLineCacheEntry')
class StockTransferChargeLinesCache extends Table {
  TextColumn get clientId          => text()();
  TextColumn get companyId         => text()();
  TextColumn get transferNo        => text()();
  TextColumn get transferDate      => text()();
  IntColumn  get serialNo          => integer()();
  TextColumn get chargeId          => text()();
  TextColumn get chargeName        => text().withDefault(const Constant(''))();
  TextColumn get nature            => text().withDefault(const Constant('ADD'))();
  TextColumn get glAccountId       => text().withDefault(const Constant(''))();
  TextColumn get amountOrPercent   => text().withDefault(const Constant('AMOUNT'))();
  RealColumn get percent           => real().nullable()();
  RealColumn get amount            => real().withDefault(const Constant(0.0))();
  BoolColumn get isDeleted         => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt      => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, transferNo, transferDate, serialNo};
}
