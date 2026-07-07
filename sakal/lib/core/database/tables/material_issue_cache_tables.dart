import 'package:drift/drift.dart';

/// Offline cache for Material Issues. Business composite key
/// (client_id, company_id, issue_no, issue_date).
@DataClassName('MaterialIssueHeaderCacheEntry')
class MaterialIssueHeadersCache extends Table {
  TextColumn get clientId     => text()();
  TextColumn get companyId    => text()();
  TextColumn get locationId   => text().withDefault(const Constant(''))();
  TextColumn get locationName => text().withDefault(const Constant(''))();
  TextColumn get issueNo      => text()();
  TextColumn get issueDate    => text()(); // 'YYYY-MM-DD'
  TextColumn get remarks      => text().withDefault(const Constant(''))();
  TextColumn get status       => text().withDefault(const Constant('DRAFT'))();
  BoolColumn get isDeleted    => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, issueNo, issueDate};
}

/// rid_material_issue_lines. batchesJson/serialsJson embed that line's
/// rid_transaction_line_batches/serials children as a JSON array directly on
/// the row — same pragmatic simplification GrnLinesCache uses.
@DataClassName('MaterialIssueLineCacheEntry')
class MaterialIssueLinesCache extends Table {
  TextColumn get clientId                   => text()();
  TextColumn get companyId                  => text()();
  TextColumn get issueNo                    => text()();
  TextColumn get issueDate                  => text()();
  IntColumn  get serialNo                   => integer()();
  TextColumn get sourceRequisitionNo        => text().withDefault(const Constant(''))();
  TextColumn get sourceRequisitionDate      => text().withDefault(const Constant(''))();
  IntColumn  get sourceRequisitionLineSerial => integer().nullable()();
  TextColumn get productId                  => text()();
  TextColumn get productCode                => text().withDefault(const Constant(''))();
  TextColumn get productName                => text().withDefault(const Constant(''))();
  TextColumn get uomId                       => text().withDefault(const Constant(''))();
  TextColumn get uomLabel                    => text().withDefault(const Constant(''))();
  RealColumn get uomConversionFactor         => real().withDefault(const Constant(1.0))();
  RealColumn get qtyPack                     => real().withDefault(const Constant(0.0))();
  RealColumn get qtyLoose                    => real().withDefault(const Constant(0.0))();
  RealColumn get baseQty                     => real().withDefault(const Constant(0.0))();
  TextColumn get departmentId                => text().withDefault(const Constant(''))();
  TextColumn get consumptionAreaId           => text().withDefault(const Constant(''))();
  TextColumn get batchesJson                 => text().withDefault(const Constant('[]'))();
  TextColumn get serialsJson                 => text().withDefault(const Constant('[]'))();
  BoolColumn get isDeleted                   => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt                => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, issueNo, issueDate, serialNo};
}
