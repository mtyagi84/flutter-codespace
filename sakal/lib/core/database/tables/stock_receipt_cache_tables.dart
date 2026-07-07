import 'package:drift/drift.dart';

/// Offline cache for Stock Receipts. Business composite key
/// (client_id, company_id, receipt_no, receipt_date).
@DataClassName('StockReceiptHeaderCacheEntry')
class StockReceiptHeadersCache extends Table {
  TextColumn get clientId           => text()();
  TextColumn get companyId          => text()();
  TextColumn get fromLocationId     => text().withDefault(const Constant(''))();
  TextColumn get fromLocationName   => text().withDefault(const Constant(''))();
  TextColumn get toLocationId       => text().withDefault(const Constant(''))();
  TextColumn get toLocationName     => text().withDefault(const Constant(''))();
  TextColumn get sourceTransferNo   => text().withDefault(const Constant(''))();
  TextColumn get sourceTransferDate => text().withDefault(const Constant(''))();
  TextColumn get receiptNo          => text()();
  TextColumn get receiptDate        => text()(); // 'YYYY-MM-DD'
  TextColumn get remarks            => text().withDefault(const Constant(''))();
  TextColumn get status             => text().withDefault(const Constant('DRAFT'))();
  BoolColumn get isDeleted          => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt       => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, receiptNo, receiptDate};
}

/// rid_stock_receipt_lines. batchesJson/serialsJson embed the confirmed
/// batch/serial allocation the same way GrnLinesCache does.
@DataClassName('StockReceiptLineCacheEntry')
class StockReceiptLinesCache extends Table {
  TextColumn get clientId                  => text()();
  TextColumn get companyId                 => text()();
  TextColumn get receiptNo                 => text()();
  TextColumn get receiptDate               => text()();
  IntColumn  get serialNo                  => integer()();
  IntColumn  get sourceTransferLineSerial  => integer().nullable()();
  TextColumn get productId                 => text()();
  TextColumn get productCode               => text().withDefault(const Constant(''))();
  TextColumn get productName               => text().withDefault(const Constant(''))();
  TextColumn get uomId                     => text().withDefault(const Constant(''))();
  TextColumn get uomLabel                  => text().withDefault(const Constant(''))();
  RealColumn get uomConversionFactor       => real().withDefault(const Constant(1.0))();
  RealColumn get receivedQtyPack           => real().withDefault(const Constant(0.0))();
  RealColumn get receivedQtyLoose          => real().withDefault(const Constant(0.0))();
  RealColumn get receivedBaseQty           => real().withDefault(const Constant(0.0))();
  TextColumn get remarks                   => text().withDefault(const Constant(''))();
  TextColumn get batchesJson               => text().withDefault(const Constant('[]'))();
  TextColumn get serialsJson               => text().withDefault(const Constant('[]'))();
  BoolColumn get isDeleted                 => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt              => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, receiptNo, receiptDate, serialNo};
}
