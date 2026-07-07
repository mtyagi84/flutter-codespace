import 'package:drift/drift.dart';

/// Offline cache for Purchase Returns — mirrors PurchaseReturnModel field-for-
/// field. Business composite key (client_id, company_id, return_no, return_date).
@DataClassName('PurchaseReturnHeaderCacheEntry')
class PurchaseReturnHeadersCache extends Table {
  TextColumn get clientId           => text()();
  TextColumn get companyId          => text()();
  TextColumn get locationId         => text().withDefault(const Constant(''))();
  TextColumn get locationName       => text().withDefault(const Constant(''))();
  TextColumn get returnNo           => text()();
  TextColumn get returnDate         => text()(); // 'YYYY-MM-DD'
  TextColumn get supplierId         => text()();
  TextColumn get supplierCode       => text().withDefault(const Constant(''))();
  TextColumn get supplierName       => text().withDefault(const Constant(''))();
  TextColumn get returnCurrencyId   => text().withDefault(const Constant(''))();
  TextColumn get returnCurrencyCode => text().withDefault(const Constant(''))();
  RealColumn get rateToBase         => real().withDefault(const Constant(1.0))();
  RealColumn get rateToLocal        => real().withDefault(const Constant(1.0))();
  RealColumn get taxableAmount      => real().withDefault(const Constant(0.0))();
  RealColumn get taxAmount          => real().withDefault(const Constant(0.0))();
  RealColumn get chargesAmount      => real().withDefault(const Constant(0.0))();
  RealColumn get returnTotal        => real().withDefault(const Constant(0.0))();
  TextColumn get reason             => text().withDefault(const Constant(''))();
  TextColumn get remarks            => text().withDefault(const Constant(''))();
  TextColumn get status             => text().withDefault(const Constant('DRAFT'))();
  TextColumn get approvedBy         => text().withDefault(const Constant(''))();
  TextColumn get approvedAt         => text().withDefault(const Constant(''))();
  TextColumn get postedVoucherNo    => text().withDefault(const Constant(''))();
  TextColumn get postedVoucherDate  => text().withDefault(const Constant(''))();
  BoolColumn get isDeleted          => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt       => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, returnNo, returnDate};
}

/// rid_purchase_return_lines. batchesJson/serialsJson embed that line's
/// batch/serial allocation the same way GrnLinesCache does. Stores the fuller
/// save-payload shape (rate/tax_group_id/gross_amount) rather than the
/// remote's own leaner getReturnLines select, since cacheFromMaps only ever
/// receives the save-payload maps — display-only fields (product name, uom
/// label) are NOT available at that point and are left blank; a return whose
/// lines were only ever cached via cacheFromMaps (never via a live getLines
/// read while online) will reload with product_id/qty/rate intact but no
/// display text, matching this module's documented offline scope.
@DataClassName('PurchaseReturnLineCacheEntry')
class PurchaseReturnLinesCache extends Table {
  TextColumn get clientId             => text()();
  TextColumn get companyId            => text()();
  TextColumn get returnNo             => text()();
  TextColumn get returnDate           => text()();
  IntColumn  get serialNo             => integer()();
  TextColumn get sourceGrnNo          => text().withDefault(const Constant(''))();
  TextColumn get sourceGrnDate        => text().withDefault(const Constant(''))();
  IntColumn  get sourceGrnLineSerial  => integer().nullable()();
  TextColumn get productId            => text()();
  TextColumn get productCode          => text().withDefault(const Constant(''))();
  TextColumn get productName          => text().withDefault(const Constant(''))();
  TextColumn get uomId                => text().withDefault(const Constant(''))();
  TextColumn get uomLabel             => text().withDefault(const Constant(''))();
  RealColumn get uomConversionFactor  => real().withDefault(const Constant(1.0))();
  RealColumn get qtyPack              => real().withDefault(const Constant(0.0))();
  RealColumn get qtyLoose             => real().withDefault(const Constant(0.0))();
  RealColumn get baseQty              => real().withDefault(const Constant(0.0))();
  RealColumn get rate                 => real().withDefault(const Constant(0.0))();
  TextColumn get taxGroupId           => text().withDefault(const Constant(''))();
  RealColumn get grossAmount          => real().withDefault(const Constant(0.0))();
  RealColumn get taxAmount            => real().withDefault(const Constant(0.0))();
  RealColumn get finalAmount          => real().withDefault(const Constant(0.0))();
  TextColumn get batchesJson          => text().withDefault(const Constant('[]'))();
  TextColumn get serialsJson          => text().withDefault(const Constant('[]'))();
  BoolColumn get isDeleted            => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt         => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, returnNo, returnDate, serialNo};
}

@DataClassName('PurchaseReturnChargeLineCacheEntry')
class PurchaseReturnChargeLinesCache extends Table {
  TextColumn get clientId       => text()();
  TextColumn get companyId      => text()();
  TextColumn get returnNo       => text()();
  TextColumn get returnDate     => text()();
  IntColumn  get serialNo       => integer()();
  TextColumn get chargeId       => text()();
  TextColumn get chargeName     => text().withDefault(const Constant(''))();
  BoolColumn get isTaxable      => boolean().withDefault(const Constant(false))();
  TextColumn get taxId          => text().withDefault(const Constant(''))();
  TextColumn get nature         => text().withDefault(const Constant('ADD'))();
  TextColumn get glAccountId    => text().withDefault(const Constant(''))();
  RealColumn get amount         => real().withDefault(const Constant(0.0))();
  RealColumn get taxAmount      => real().withDefault(const Constant(0.0))();
  TextColumn get sourceGrnNo    => text().withDefault(const Constant(''))();
  TextColumn get sourceGrnDate  => text().withDefault(const Constant(''))();
  BoolColumn get isDeleted      => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt   => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, returnNo, returnDate, serialNo};
}
