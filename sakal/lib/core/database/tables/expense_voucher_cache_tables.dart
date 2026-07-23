import 'package:drift/drift.dart';

/// Offline cache for Expense Vouchers — mirrors the header/lines shape
/// saved via fn_save_expense_voucher (107_expense_voucher.sql). Business
/// composite key (client_id, company_id, trans_no, trans_date), same
/// shape as every other transaction cache table.
///
/// Offline-created rows use a locally generated placeholder transNo
/// (LOCAL-<timestamp>-<rand>, via generateLocalId()) until SyncEngine
/// renames it to the real server-assigned number on sync.
@DataClassName('ExpenseVoucherCacheEntry')
class ExpenseVoucherHeadersCache extends Table {
  TextColumn get clientId => text()();
  TextColumn get companyId => text()();
  TextColumn get locationId => text().withDefault(const Constant(''))();
  TextColumn get transNo => text()();
  TextColumn get transDate => text()(); // 'YYYY-MM-DD'
  TextColumn get supplierId => text()();
  TextColumn get supplierCode => text().withDefault(const Constant(''))();
  TextColumn get supplierName => text().withDefault(const Constant(''))();
  TextColumn get currencyId => text()();
  TextColumn get currencyCode => text().withDefault(const Constant(''))();
  RealColumn get rateToBase => real().withDefault(const Constant(1.0))();
  RealColumn get rateToLocal => real().withDefault(const Constant(1.0))();
  TextColumn get billNo => text().withDefault(const Constant(''))();
  TextColumn get billDate => text().withDefault(const Constant(''))();
  TextColumn get remarks => text().withDefault(const Constant(''))();
  TextColumn get status => text().withDefault(const Constant('DRAFT'))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, transNo, transDate};
}

@DataClassName('ExpenseVoucherLineCacheEntry')
class ExpenseVoucherLinesCache extends Table {
  TextColumn get clientId => text()();
  TextColumn get companyId => text()();
  TextColumn get transNo => text()();
  TextColumn get transDate => text()();
  IntColumn get serialNo => integer()();
  TextColumn get accountId => text()();
  TextColumn get accountCode => text().withDefault(const Constant(''))();
  TextColumn get accountName => text().withDefault(const Constant(''))();
  RealColumn get amount => real().withDefault(const Constant(0.0))();
  TextColumn get taxGroupId => text().withDefault(const Constant(''))();
  TextColumn get taxGroupName => text().withDefault(const Constant(''))();
  TextColumn get lineRemarks => text().withDefault(const Constant(''))();
  DateTimeColumn get cachedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, transNo, transDate, serialNo};
}
