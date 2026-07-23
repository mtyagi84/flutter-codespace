import 'package:drift/drift.dart';

/// Offline cache for Cash Receipts — mirrors the header/lines shape
/// saved via fn_save_cash_receipt (104_cash_receipt.sql). Business
/// composite key (client_id, company_id, receipt_no, receipt_date),
/// same shape as every other transaction cache table.
///
/// Offline-created rows use a locally generated placeholder receiptNo
/// (LOCAL-<timestamp>-<rand>, via generateLocalId()) until SyncEngine
/// renames it to the real server-assigned number on sync — see the
/// 'CASH_RECEIPT' case in sync_engine.dart's _renameLocalDocument.
@DataClassName('CashReceiptCacheEntry')
class CashReceiptHeadersCache extends Table {
  TextColumn get clientId => text()();
  TextColumn get companyId => text()();
  TextColumn get locationId => text().withDefault(const Constant(''))();
  TextColumn get locationName => text().withDefault(const Constant(''))();
  TextColumn get receiptNo => text()();
  TextColumn get receiptDate => text()(); // 'YYYY-MM-DD'
  TextColumn get customerId => text()();
  TextColumn get customerCode => text().withDefault(const Constant(''))();
  TextColumn get customerName => text().withDefault(const Constant(''))();
  RealColumn get localAmount => real().withDefault(const Constant(0.0))();
  RealColumn get baseAmount => real().withDefault(const Constant(0.0))();
  TextColumn get remarks => text().withDefault(const Constant(''))();
  TextColumn get status => text().withDefault(const Constant('DRAFT'))();
  TextColumn get crvLocalVoucherNo => text().withDefault(const Constant(''))();
  TextColumn get crvBaseVoucherNo => text().withDefault(const Constant(''))();
  TextColumn get excVoucherNo => text().withDefault(const Constant(''))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, receiptNo, receiptDate};
}

@DataClassName('CashReceiptLineCacheEntry')
class CashReceiptLinesCache extends Table {
  TextColumn get clientId => text()();
  TextColumn get companyId => text()();
  TextColumn get receiptNo => text()();
  TextColumn get receiptDate => text()();
  IntColumn get serialNo => integer()();
  TextColumn get invBillNo => text()();
  TextColumn get invBillDate => text()();
  TextColumn get billCurrency => text().withDefault(const Constant(''))();
  RealColumn get appliedAmountLocal => real().withDefault(const Constant(0.0))();
  DateTimeColumn get cachedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, receiptNo, receiptDate, serialNo};
}
