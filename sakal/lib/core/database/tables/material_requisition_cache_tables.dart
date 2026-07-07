import 'package:drift/drift.dart';

/// Offline cache for Material Requisitions. Business composite key
/// (client_id, company_id, requisition_no, requisition_date) — same
/// convention as every other cache table in this file family.
@DataClassName('MaterialRequisitionHeaderCacheEntry')
class MaterialRequisitionHeadersCache extends Table {
  TextColumn get clientId       => text()();
  TextColumn get companyId      => text()();
  TextColumn get locationId     => text().withDefault(const Constant(''))();
  TextColumn get locationName   => text().withDefault(const Constant(''))();
  TextColumn get requisitionNo  => text()();
  TextColumn get requisitionDate => text()(); // 'YYYY-MM-DD'
  TextColumn get requestedBy    => text().withDefault(const Constant(''))();
  TextColumn get reason         => text().withDefault(const Constant(''))();
  TextColumn get remarks        => text().withDefault(const Constant(''))();
  TextColumn get status         => text().withDefault(const Constant('DRAFT'))();
  BoolColumn get isDeleted      => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt   => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, requisitionNo, requisitionDate};
}

@DataClassName('MaterialRequisitionLineCacheEntry')
class MaterialRequisitionLinesCache extends Table {
  TextColumn get clientId             => text()();
  TextColumn get companyId            => text()();
  TextColumn get requisitionNo        => text()();
  TextColumn get requisitionDate      => text()();
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
  TextColumn get departmentId         => text().withDefault(const Constant(''))();
  TextColumn get departmentLabel      => text().withDefault(const Constant(''))();
  TextColumn get consumptionAreaId    => text().withDefault(const Constant(''))();
  TextColumn get areaLabel            => text().withDefault(const Constant(''))();
  RealColumn get issuedQty            => real().withDefault(const Constant(0.0))();
  TextColumn get remarks              => text().withDefault(const Constant(''))();
  BoolColumn get isDeleted            => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt         => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, requisitionNo, requisitionDate, serialNo};
}
