import 'package:drift/drift.dart';

/// Offline cache for Sales Deliveries — mirrors the header/lines shape
/// saved via fn_save_sales_delivery (102_sales_delivery.sql). Business
/// composite key (client_id, company_id, delivery_no, delivery_date),
/// same shape as every other transaction cache table.
///
/// Batch/serial allocations and Transport Details are NOT cached locally
/// — same documented, accepted limitation Sales Invoice/Sales Return
/// already carry for their own offline paths (reopening an offline-
/// created DRAFT while still offline loses these; low-risk, re-enterable).
///
/// Offline-created rows use a locally generated placeholder deliveryNo
/// (LOCAL-<timestamp>-<rand>, via generateLocalId()) until SyncEngine
/// renames it to the real server-assigned number on sync — see the
/// 'SALES_DELIVERY' case in sync_engine.dart's _renameLocalDocument.
@DataClassName('SalesDeliveryCacheEntry')
class SalesDeliveriesCache extends Table {
  TextColumn get clientId              => text()();
  TextColumn get companyId             => text()();
  TextColumn get locationId            => text().withDefault(const Constant(''))();
  TextColumn get locationName          => text().withDefault(const Constant(''))();
  TextColumn get deliveryNo            => text()();
  TextColumn get deliveryDate          => text()(); // 'YYYY-MM-DD'
  TextColumn get invoiceNo             => text()();
  TextColumn get invoiceDate           => text()();
  TextColumn get customerId            => text()();
  TextColumn get customerCode          => text().withDefault(const Constant(''))();
  TextColumn get customerName          => text().withDefault(const Constant(''))();
  TextColumn get shipToLocationId      => text().withDefault(const Constant(''))();
  TextColumn get shipToLocationName    => text().withDefault(const Constant(''))();
  TextColumn get shipToAddressLine1    => text().withDefault(const Constant(''))();
  TextColumn get shipToAddressLine2    => text().withDefault(const Constant(''))();
  TextColumn get shipToCityId          => text().withDefault(const Constant(''))();
  TextColumn get shipToContactPerson   => text().withDefault(const Constant(''))();
  TextColumn get shipToContactPhone    => text().withDefault(const Constant(''))();
  TextColumn get receivedByName        => text().withDefault(const Constant(''))();
  TextColumn get reason                => text().withDefault(const Constant(''))();
  TextColumn get remarks               => text().withDefault(const Constant(''))();
  TextColumn get status                => text().withDefault(const Constant('DRAFT'))();
  TextColumn get cosVoucherNo          => text().withDefault(const Constant(''))();
  TextColumn get cosVoucherDate        => text().withDefault(const Constant(''))();
  BoolColumn get isDeleted             => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt          => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, deliveryNo, deliveryDate};
}

@DataClassName('SalesDeliveryLineCacheEntry')
class SalesDeliveryLinesCache extends Table {
  TextColumn get clientId              => text()();
  TextColumn get companyId             => text()();
  TextColumn get deliveryNo            => text()();
  TextColumn get deliveryDate          => text()();
  IntColumn  get serialNo              => integer()();
  IntColumn  get invoiceLineSerial     => integer().withDefault(const Constant(0))();
  TextColumn get productId             => text()();
  TextColumn get productCode           => text().withDefault(const Constant(''))();
  TextColumn get productName           => text().withDefault(const Constant(''))();
  TextColumn get barcode               => text().withDefault(const Constant(''))();
  TextColumn get uomId                 => text()();
  TextColumn get uomLabel              => text().withDefault(const Constant(''))();
  RealColumn get uomConversionFactor   => real().withDefault(const Constant(1.0))();
  RealColumn get qtyPack               => real().withDefault(const Constant(0.0))();
  RealColumn get qtyLoose              => real().withDefault(const Constant(0.0))();
  RealColumn get baseQty               => real().withDefault(const Constant(0.0))();
  DateTimeColumn get cachedAt          => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, deliveryNo, deliveryDate, serialNo};
}
