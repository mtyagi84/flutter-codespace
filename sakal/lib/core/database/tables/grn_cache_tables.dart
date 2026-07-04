import 'package:drift/drift.dart';

/// Offline cache for Goods Receipt Notes — mirrors rih_grn_headers field-for-
/// field. Business composite key (client_id, company_id, grn_no, grn_date),
/// same convention as PurchaseOrdersCache.
@DataClassName('GrnHeaderCacheEntry')
class GrnHeadersCache extends Table {
  TextColumn get clientId              => text()();
  TextColumn get companyId             => text()();
  TextColumn get locationId            => text().withDefault(const Constant(''))();
  TextColumn get locationName          => text().withDefault(const Constant(''))();
  TextColumn get grnNo                 => text()();
  TextColumn get grnDate               => text()(); // 'YYYY-MM-DD'
  TextColumn get supplierId            => text()();
  TextColumn get supplierCode          => text().withDefault(const Constant(''))();
  TextColumn get supplierName          => text().withDefault(const Constant(''))();
  TextColumn get receiptMode           => text().withDefault(const Constant('DIRECT'))();
  TextColumn get supplierDeliveryNo    => text().withDefault(const Constant(''))();
  TextColumn get supplierDeliveryDate  => text().withDefault(const Constant(''))();
  TextColumn get grnCurrencyId         => text().withDefault(const Constant(''))();
  TextColumn get grnCurrencyCode       => text().withDefault(const Constant(''))();
  RealColumn get rateToBase            => real().withDefault(const Constant(1.0))();
  RealColumn get rateToLocal           => real().withDefault(const Constant(1.0))();
  RealColumn get grossAmount           => real().withDefault(const Constant(0.0))();
  RealColumn get discountAmount        => real().withDefault(const Constant(0.0))();
  RealColumn get chargesAmount         => real().withDefault(const Constant(0.0))();
  RealColumn get itemTaxAmount         => real().withDefault(const Constant(0.0))();
  RealColumn get chargeTaxAmount       => real().withDefault(const Constant(0.0))();
  RealColumn get grandTotal            => real().withDefault(const Constant(0.0))();
  TextColumn get billTo                => text().withDefault(const Constant(''))();
  TextColumn get shipTo                => text().withDefault(const Constant(''))();
  TextColumn get remarks               => text().withDefault(const Constant(''))();
  TextColumn get status                => text().withDefault(const Constant('DRAFT'))();
  TextColumn get approvedBy            => text().withDefault(const Constant(''))();
  TextColumn get approvedAt            => text().withDefault(const Constant(''))();
  TextColumn get postedVoucherNo       => text().withDefault(const Constant(''))();
  TextColumn get postedVoucherDate     => text().withDefault(const Constant(''))();
  BoolColumn get isDeleted             => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt          => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, grnNo, grnDate};
}

/// rid_grn_lines. batchesJson/serialsJson embed that line's
/// rid_transaction_line_batches/rid_transaction_line_serials children as a
/// JSON array directly on the row — a pragmatic simplification versus two
/// more generic-doc-type Drift tables purely for offline read-back; the
/// server-side tables remain the real, generic, document-type-keyed ones.
@DataClassName('GrnLineCacheEntry')
class GrnLinesCache extends Table {
  TextColumn get clientId             => text()();
  TextColumn get companyId            => text()();
  TextColumn get grnNo                => text()();
  TextColumn get grnDate              => text()();
  IntColumn  get serialNo             => integer()();
  TextColumn get productId            => text()();
  TextColumn get productCode          => text().withDefault(const Constant(''))();
  TextColumn get productName          => text().withDefault(const Constant(''))();
  TextColumn get sourcePoOrderNo      => text().withDefault(const Constant(''))();
  TextColumn get sourcePoOrderDate    => text().withDefault(const Constant(''))();
  IntColumn  get sourcePoLineSerial   => integer().nullable()();
  TextColumn get itemDescription      => text().withDefault(const Constant(''))();
  TextColumn get uomId                => text().withDefault(const Constant(''))();
  TextColumn get uomLabel             => text().withDefault(const Constant(''))();
  RealColumn get uomConversionFactor  => real().withDefault(const Constant(1.0))();
  RealColumn get qtyPack              => real().withDefault(const Constant(0.0))();
  RealColumn get qtyLoose             => real().withDefault(const Constant(0.0))();
  RealColumn get baseQty              => real().withDefault(const Constant(0.0))();
  RealColumn get rate                 => real().withDefault(const Constant(0.0))();
  RealColumn get grossAmount          => real().withDefault(const Constant(0.0))();
  RealColumn get discountPercent      => real().withDefault(const Constant(0.0))();
  RealColumn get discountAmount       => real().withDefault(const Constant(0.0))();
  TextColumn get taxGroupId           => text().withDefault(const Constant(''))();
  TextColumn get taxGroupName         => text().withDefault(const Constant(''))();
  RealColumn get taxAmount            => real().withDefault(const Constant(0.0))();
  RealColumn get finalAmount          => real().withDefault(const Constant(0.0))();
  RealColumn get baseAmount           => real().withDefault(const Constant(0.0))();
  RealColumn get localAmount          => real().withDefault(const Constant(0.0))();
  RealColumn get chargeAmount         => real().withDefault(const Constant(0.0))();
  RealColumn get landedAmount         => real().withDefault(const Constant(0.0))();
  TextColumn get departmentId         => text().withDefault(const Constant(''))();
  TextColumn get consumptionAreaId    => text().withDefault(const Constant(''))();
  TextColumn get batchesJson          => text().withDefault(const Constant('[]'))();
  TextColumn get serialsJson          => text().withDefault(const Constant('[]'))();
  BoolColumn get isDeleted            => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt         => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, grnNo, grnDate, serialNo};
}

/// rid_grn_charge_lines — same shape as PoChargeLinesCache plus the
/// source_po_* traceability columns.
@DataClassName('GrnChargeLineCacheEntry')
class GrnChargeLinesCache extends Table {
  TextColumn get clientId          => text()();
  TextColumn get companyId         => text()();
  TextColumn get grnNo             => text()();
  TextColumn get grnDate           => text()();
  IntColumn  get serialNo          => integer()();
  TextColumn get chargeId          => text()();
  TextColumn get chargeName        => text().withDefault(const Constant(''))();
  BoolColumn get isTaxable         => boolean().withDefault(const Constant(false))();
  TextColumn get taxId             => text().withDefault(const Constant(''))();
  TextColumn get nature            => text().withDefault(const Constant('ADD'))();
  TextColumn get glAccountId       => text().withDefault(const Constant(''))();
  TextColumn get amountOrPercent   => text().withDefault(const Constant('AMOUNT'))();
  RealColumn get percent           => real().nullable()();
  RealColumn get amount            => real().withDefault(const Constant(0.0))();
  RealColumn get taxAmount         => real().withDefault(const Constant(0.0))();
  RealColumn get allocationFactor  => real().nullable()();
  TextColumn get sourcePoOrderNo   => text().withDefault(const Constant(''))();
  TextColumn get sourcePoOrderDate => text().withDefault(const Constant(''))();
  BoolColumn get isDeleted         => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt      => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, grnNo, grnDate, serialNo};
}
