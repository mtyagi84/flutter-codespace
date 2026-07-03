import 'package:drift/drift.dart';

/// Offline cache for Purchase Orders — mirrors PurchaseOrderModel field-for-
/// field. Business composite key (client_id, company_id, order_no, order_date)
/// since PO numbers are only assigned by fn_next_company_doc_no on first save,
/// same convention as FinanceVoucherHeadersCache's (trans_no, trans_date) key.
@DataClassName('PurchaseOrderCacheEntry')
class PurchaseOrdersCache extends Table {
  TextColumn get clientId        => text()();
  TextColumn get companyId       => text()();
  TextColumn get locationId      => text().withDefault(const Constant(''))();
  TextColumn get locationName    => text().withDefault(const Constant(''))();
  TextColumn get orderNo         => text()();
  TextColumn get orderDate       => text()(); // 'YYYY-MM-DD'
  TextColumn get poType          => text().withDefault(const Constant('LOCAL'))();
  TextColumn get supplierId      => text()();
  TextColumn get supplierCode    => text().withDefault(const Constant(''))();
  TextColumn get supplierName    => text().withDefault(const Constant(''))();
  TextColumn get supplierRefNo   => text().withDefault(const Constant(''))();
  TextColumn get supplierRefDate => text().withDefault(const Constant(''))();
  TextColumn get indentNo        => text().withDefault(const Constant(''))();
  TextColumn get indentDate      => text().withDefault(const Constant(''))();
  TextColumn get rfqNo           => text().withDefault(const Constant(''))();
  TextColumn get rfqDate         => text().withDefault(const Constant(''))();
  TextColumn get quotationNo     => text().withDefault(const Constant(''))();
  TextColumn get quotationDate   => text().withDefault(const Constant(''))();
  TextColumn get paymentTerms    => text().withDefault(const Constant(''))();
  TextColumn get poCurrencyId    => text()();
  TextColumn get poCurrencyCode  => text().withDefault(const Constant(''))();
  RealColumn get rateToBase      => real().withDefault(const Constant(1.0))();
  RealColumn get rateToLocal     => real().withDefault(const Constant(1.0))();
  RealColumn get grossAmount     => real().withDefault(const Constant(0.0))();
  RealColumn get discountAmount  => real().withDefault(const Constant(0.0))();
  RealColumn get chargesAmount   => real().withDefault(const Constant(0.0))();
  RealColumn get itemTaxAmount   => real().withDefault(const Constant(0.0))();
  RealColumn get chargeTaxAmount => real().withDefault(const Constant(0.0))();
  RealColumn get grandTotal      => real().withDefault(const Constant(0.0))();
  TextColumn get buyerId         => text().withDefault(const Constant(''))();
  TextColumn get buyerName       => text().withDefault(const Constant(''))();
  TextColumn get status          => text().withDefault(const Constant('DRAFT'))();
  TextColumn get approvedBy      => text().withDefault(const Constant(''))();
  TextColumn get approvedAt      => text().withDefault(const Constant(''))();
  TextColumn get orderSubject    => text().withDefault(const Constant(''))();
  TextColumn get billTo          => text().withDefault(const Constant(''))();
  TextColumn get shipTo          => text().withDefault(const Constant(''))();
  TextColumn get remarks         => text().withDefault(const Constant(''))();
  BoolColumn get isDeleted       => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt    => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, orderNo, orderDate};
}

@DataClassName('PurchaseOrderLineCacheEntry')
class PurchaseOrderLinesCache extends Table {
  TextColumn get clientId             => text()();
  TextColumn get companyId            => text()();
  TextColumn get orderNo              => text()();
  TextColumn get orderDate            => text()();
  IntColumn  get serialNo             => integer()();
  TextColumn get productId            => text()();
  TextColumn get productCode          => text().withDefault(const Constant(''))();
  TextColumn get productName          => text().withDefault(const Constant(''))();
  TextColumn get itemDescription      => text().withDefault(const Constant(''))();
  TextColumn get barcode              => text().withDefault(const Constant(''))();
  TextColumn get uomId                => text()();
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
  RealColumn get qtyOnHandAtOrder     => real().nullable()();
  RealColumn get reorderLevelAtOrder  => real().nullable()();
  RealColumn get qtyReceived          => real().withDefault(const Constant(0.0))();
  BoolColumn get isDeleted            => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt         => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, orderNo, orderDate, serialNo};
}

@DataClassName('PoChargeLineCacheEntry')
class PoChargeLinesCache extends Table {
  TextColumn get clientId          => text()();
  TextColumn get companyId         => text()();
  TextColumn get orderNo           => text()();
  TextColumn get orderDate         => text()();
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
  BoolColumn get isDeleted         => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt      => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, orderNo, orderDate, serialNo};
}
