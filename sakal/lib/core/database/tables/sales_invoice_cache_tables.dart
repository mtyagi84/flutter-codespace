import 'package:drift/drift.dart';

/// Offline cache for Sales Invoices — mirrors the header/lines shape saved
/// via fn_save_sales_invoice (089_sales_invoice.sql). Business composite key
/// (client_id, company_id, invoice_no, invoice_date), same shape as every
/// other transaction cache table. Only the header's own chargesAmount
/// rollup is cached (keeps the offline list screen + a reopened DRAFT's
/// totals breakdown accurate) — the actual charge line items
/// (rid_sales_invoice_charges) are NOT cached locally, same narrow,
/// documented limitation as batch/serial allocations on an offline-created
/// DRAFT (see project_sales_invoice_module.md): reopening such a DRAFT
/// while still offline shows an empty Charges card even though the
/// invoice's own grandTotal (fully preserved) already reflects them.
///
/// Offline-created rows use a locally generated placeholder invoiceNo
/// (LOCAL-<timestamp>-<rand>, via generateLocalId()) until SyncEngine
/// renames it to the real server-assigned number on sync — see the
/// 'SALES_INVOICE' case in sync_engine.dart's _renameLocalDocument.
@DataClassName('SalesInvoiceCacheEntry')
class SalesInvoicesCache extends Table {
  TextColumn get clientId              => text()();
  TextColumn get companyId             => text()();
  TextColumn get locationId            => text().withDefault(const Constant(''))();
  TextColumn get locationName          => text().withDefault(const Constant(''))();
  TextColumn get invoiceNo             => text()();
  TextColumn get invoiceDate           => text()(); // 'YYYY-MM-DD'
  TextColumn get invoiceMode           => text().withDefault(const Constant('DIRECT'))(); // DIRECT | AGAINST_QUOTATION | AGAINST_ORDER
  TextColumn get quotationNo           => text().withDefault(const Constant(''))();
  TextColumn get quotationDate         => text().withDefault(const Constant(''))();
  TextColumn get orderNo               => text().withDefault(const Constant(''))();
  TextColumn get orderDate             => text().withDefault(const Constant(''))();
  TextColumn get saleType              => text().withDefault(const Constant('CASH'))(); // CASH | CREDIT
  TextColumn get customerId            => text()();
  TextColumn get customerCode          => text().withDefault(const Constant(''))();
  TextColumn get customerName          => text().withDefault(const Constant(''))();
  // Cash-sale walk-in snapshot only — always empty for CREDIT.
  TextColumn get partyName             => text().withDefault(const Constant(''))();
  TextColumn get partyPhone            => text().withDefault(const Constant(''))();
  TextColumn get partyAddress          => text().withDefault(const Constant(''))();
  TextColumn get salesPersonId         => text().withDefault(const Constant(''))();
  TextColumn get salesPersonName       => text().withDefault(const Constant(''))();
  TextColumn get invoiceCurrencyId     => text()();
  TextColumn get invoiceCurrencyCode   => text().withDefault(const Constant(''))();
  RealColumn get rateToBase            => real().withDefault(const Constant(1.0))();
  RealColumn get rateToLocal           => real().withDefault(const Constant(1.0))();
  // Header fan-out convenience only (see 089's own header comment) — not
  // re-validated, purely a record of what blanket discount was applied.
  RealColumn get discountPercent       => real().withDefault(const Constant(0.0))();
  RealColumn get grossAmount           => real().withDefault(const Constant(0.0))();
  RealColumn get discountAmount        => real().withDefault(const Constant(0.0))();
  RealColumn get chargesAmount         => real().withDefault(const Constant(0.0))();
  RealColumn get taxAmount             => real().withDefault(const Constant(0.0))();
  RealColumn get grandTotal            => real().withDefault(const Constant(0.0))();
  // Snapshotted from company flags at save time — IMMEDIATE | DEFERRED.
  TextColumn get stockDispatchMode     => text().withDefault(const Constant('IMMEDIATE'))();
  TextColumn get cashCollectionMode    => text().withDefault(const Constant('IMMEDIATE'))();
  TextColumn get status                => text().withDefault(const Constant('DRAFT'))();
  TextColumn get salesVoucherNo        => text().withDefault(const Constant(''))();
  TextColumn get salesVoucherDate      => text().withDefault(const Constant(''))();
  TextColumn get cosVoucherNo          => text().withDefault(const Constant(''))();
  TextColumn get cosVoucherDate        => text().withDefault(const Constant(''))();
  TextColumn get localReceiptVoucherNo   => text().withDefault(const Constant(''))();
  TextColumn get localReceiptVoucherDate => text().withDefault(const Constant(''))();
  TextColumn get baseReceiptVoucherNo    => text().withDefault(const Constant(''))();
  TextColumn get baseReceiptVoucherDate  => text().withDefault(const Constant(''))();
  RealColumn get collectedAmountLocal  => real().nullable()();
  RealColumn get collectedAmountBase   => real().nullable()();
  TextColumn get cancellationReason    => text().withDefault(const Constant(''))();
  TextColumn get remarks               => text().withDefault(const Constant(''))();
  BoolColumn get isDeleted             => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt          => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, invoiceNo, invoiceDate};
}

@DataClassName('SalesInvoiceLineCacheEntry')
class SalesInvoiceLinesCache extends Table {
  TextColumn get clientId                  => text()();
  TextColumn get companyId                 => text()();
  TextColumn get invoiceNo                 => text()();
  TextColumn get invoiceDate               => text()();
  IntColumn  get serialNo                  => integer()();
  TextColumn get productId                 => text()();
  TextColumn get productCode               => text().withDefault(const Constant(''))();
  TextColumn get productName               => text().withDefault(const Constant(''))();
  TextColumn get itemDescription           => text().withDefault(const Constant(''))();
  TextColumn get barcode                   => text().withDefault(const Constant(''))();
  TextColumn get uomId                     => text()();
  TextColumn get uomLabel                  => text().withDefault(const Constant(''))();
  RealColumn get uomConversionFactor       => real().withDefault(const Constant(1.0))();
  RealColumn get qtyPack                   => real().withDefault(const Constant(0.0))();
  RealColumn get qtyLoose                  => real().withDefault(const Constant(0.0))();
  RealColumn get baseQty                   => real().withDefault(const Constant(0.0))();
  RealColumn get rate                      => real().withDefault(const Constant(0.0))();
  TextColumn get priceSource               => text().withDefault(const Constant('PRICE_MASTER'))();
  TextColumn get priceOverrideReason       => text().withDefault(const Constant(''))();
  TextColumn get priceSourceEntryNo        => text().withDefault(const Constant(''))();
  RealColumn get grossAmount               => real().withDefault(const Constant(0.0))();
  RealColumn get discountPercent           => real().withDefault(const Constant(0.0))();
  RealColumn get discountAmount            => real().withDefault(const Constant(0.0))();
  // Audit trail of who authorized this line's discount — the cashier's own
  // id when in-cap, a verified supervisor's id when overridden. Never null
  // whenever discountPercent > 0.
  TextColumn get discountGivenBy           => text().withDefault(const Constant(''))();
  TextColumn get discountGivenByName       => text().withDefault(const Constant(''))();
  TextColumn get taxGroupId                => text().withDefault(const Constant(''))();
  TextColumn get taxGroupName              => text().withDefault(const Constant(''))();
  RealColumn get taxAmount                 => real().withDefault(const Constant(0.0))();
  RealColumn get finalAmount               => real().withDefault(const Constant(0.0))();
  RealColumn get baseAmount                => real().withDefault(const Constant(0.0))();
  RealColumn get localAmount               => real().withDefault(const Constant(0.0))();
  // rid_sales_invoice_lines' own source_quotation_line_serial/
  // source_order_line_serial — line-level columns, deliberately kept with
  // their "source_" prefix (only the header-level quotationNo/orderNo on
  // the invoice itself had that prefix dropped).
  IntColumn  get sourceQuotationLineSerial => integer().nullable()();
  IntColumn  get sourceOrderLineSerial     => integer().nullable()();
  // Cost/margin — populated only when session.canViewCostPrice is true;
  // never fetched otherwise, same precedent as Sales Order's own cache.
  RealColumn get costPrice                 => real().nullable()();
  TextColumn get remarks                   => text().withDefault(const Constant(''))();
  BoolColumn get isDeleted                 => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt              => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, invoiceNo, invoiceDate, serialNo};
}
