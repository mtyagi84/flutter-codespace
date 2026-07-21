import 'package:drift/drift.dart';

/// Offline cache for Sales Returns (offline-SAVE retrofit, 2026-07-21) —
/// mirrors the header/lines shape saved via fn_save_sales_return
/// (099_sales_return.sql). Business composite key (client_id, company_id,
/// return_no, return_date), same shape as every other transaction cache
/// table.
///
/// Batch/serial allocations are NOT cached locally — same documented,
/// accepted limitation Sales Invoice's own offline path already carries
/// (reopening an offline-created DRAFT while still offline loses these;
/// low-risk, re-enterable). Charge lines are likewise not cached, mirroring
/// Sales Invoice's own charges limitation — only the header's own
/// chargesAmount rollup is kept for an accurate reopened-DRAFT total.
///
/// Offline-created rows use a locally generated placeholder returnNo
/// (LOCAL-<timestamp>-<rand>, via generateLocalId()) until SyncEngine
/// renames it to the real server-assigned number on sync — see the
/// 'SALES_RETURN' case in sync_engine.dart's _renameLocalDocument.
///
/// Approve is NEVER queued offline for Sales Return — only Save. A
/// synced-but-unapproved DRAFT is picked up by the unified Pending
/// Approvals screen, same as Sales Invoice's own offline Direct-mode
/// drafts.
@DataClassName('SalesReturnCacheEntry')
class SalesReturnHeadersCache extends Table {
  TextColumn get clientId              => text()();
  TextColumn get companyId             => text()();
  TextColumn get locationId            => text().withDefault(const Constant(''))();
  TextColumn get returnNo              => text()();
  TextColumn get returnDate            => text()(); // 'YYYY-MM-DD'
  TextColumn get invoiceNo             => text()();
  TextColumn get invoiceDate           => text()();
  TextColumn get customerId            => text()();
  TextColumn get customerCode          => text().withDefault(const Constant(''))();
  TextColumn get customerName          => text().withDefault(const Constant(''))();
  TextColumn get returnCurrencyId      => text().withDefault(const Constant(''))();
  RealColumn get rateToBase            => real().withDefault(const Constant(1.0))();
  RealColumn get rateToLocal           => real().withDefault(const Constant(1.0))();
  RealColumn get taxableAmount         => real().withDefault(const Constant(0.0))();
  RealColumn get taxAmount             => real().withDefault(const Constant(0.0))();
  RealColumn get chargesAmount         => real().withDefault(const Constant(0.0))();
  RealColumn get returnTotal           => real().withDefault(const Constant(0.0))();
  RealColumn get refundAmountLocal     => real().withDefault(const Constant(0.0))();
  RealColumn get refundAmountBase      => real().withDefault(const Constant(0.0))();
  TextColumn get reason                => text().withDefault(const Constant(''))();
  TextColumn get remarks               => text().withDefault(const Constant(''))();
  TextColumn get status                => text().withDefault(const Constant('DRAFT'))();
  TextColumn get creditNoteVoucherNo   => text().withDefault(const Constant(''))();
  TextColumn get creditNoteVoucherDate => text().withDefault(const Constant(''))();
  TextColumn get cosVoucherNo          => text().withDefault(const Constant(''))();
  TextColumn get cosVoucherDate        => text().withDefault(const Constant(''))();
  TextColumn get refundVoucherNoLocal  => text().withDefault(const Constant(''))();
  TextColumn get refundVoucherNoBase   => text().withDefault(const Constant(''))();
  BoolColumn get isDeleted             => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt          => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, returnNo, returnDate};
}

@DataClassName('SalesReturnLineCacheEntry')
class SalesReturnLinesCache extends Table {
  TextColumn get clientId              => text()();
  TextColumn get companyId             => text()();
  TextColumn get returnNo              => text()();
  TextColumn get returnDate            => text()();
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
  RealColumn get rate                  => real().withDefault(const Constant(0.0))();
  TextColumn get taxGroupId            => text().withDefault(const Constant(''))();
  RealColumn get taxAmount             => real().withDefault(const Constant(0.0))();
  RealColumn get finalAmount           => real().withDefault(const Constant(0.0))();
  RealColumn get chargeAmount          => real().withDefault(const Constant(0.0))();
  RealColumn get landedAmount          => real().withDefault(const Constant(0.0))();
  DateTimeColumn get cachedAt          => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, returnNo, returnDate, serialNo};
}
