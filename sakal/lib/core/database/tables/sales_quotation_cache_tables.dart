import 'package:drift/drift.dart';

/// Offline cache for Sales Quotations — mirrors the header/lines/charges
/// shape saved via fn_save_sales_quotation. Business composite key
/// (client_id, company_id, quotation_no, quotation_date) — same shape as
/// PurchaseOrdersCache's (order_no, order_date) key. locationId is a plain
/// display/editable column only (which location this quotation is FROM,
/// an input to fn_next_trans_no's per-location numbering sequence) — it is
/// deliberately NOT part of the key, matching the backend's
/// rih_sales_quotations (see 081_sales_quotation.sql: location_id lives on
/// the header as a plain column, same shape as GRN/Material Requisition,
/// not the location-inclusive composite key Finance Vouchers use).
@DataClassName('SalesQuotationCacheEntry')
class SalesQuotationsCache extends Table {
  TextColumn get clientId              => text()();
  TextColumn get companyId             => text()();
  TextColumn get locationId            => text().withDefault(const Constant(''))();
  TextColumn get locationName          => text().withDefault(const Constant(''))();
  TextColumn get quotationNo           => text()();
  TextColumn get quotationDate         => text()(); // 'YYYY-MM-DD'
  TextColumn get validUntilDate        => text().withDefault(const Constant(''))();
  TextColumn get customerType          => text().withDefault(const Constant('CUSTOMER'))();
  TextColumn get customerId            => text().withDefault(const Constant(''))(); // empty = PROSPECT
  TextColumn get customerCode          => text().withDefault(const Constant(''))();
  TextColumn get customerName          => text().withDefault(const Constant(''))();
  TextColumn get partyName             => text().withDefault(const Constant(''))();
  TextColumn get partyPhone            => text().withDefault(const Constant(''))();
  TextColumn get partyEmail            => text().withDefault(const Constant(''))();
  TextColumn get partyAddress          => text().withDefault(const Constant(''))();
  TextColumn get salesPersonId         => text().withDefault(const Constant(''))();
  TextColumn get salesPersonName       => text().withDefault(const Constant(''))();
  TextColumn get quotationCurrencyId   => text()();
  TextColumn get quotationCurrencyCode => text().withDefault(const Constant(''))();
  RealColumn get rateToBase            => real().withDefault(const Constant(1.0))();
  RealColumn get rateToLocal           => real().withDefault(const Constant(1.0))();
  TextColumn get paymentTerms          => text().withDefault(const Constant(''))();
  TextColumn get deliveryTerms         => text().withDefault(const Constant(''))();
  RealColumn get grossAmount           => real().withDefault(const Constant(0.0))();
  RealColumn get discountAmount        => real().withDefault(const Constant(0.0))();
  RealColumn get chargesAmount         => real().withDefault(const Constant(0.0))();
  RealColumn get taxAmount             => real().withDefault(const Constant(0.0))();
  RealColumn get grandTotal            => real().withDefault(const Constant(0.0))();
  TextColumn get status                => text().withDefault(const Constant('DRAFT'))();
  TextColumn get approvedBy            => text().withDefault(const Constant(''))();
  TextColumn get approvedAt            => text().withDefault(const Constant(''))();
  TextColumn get remarks               => text().withDefault(const Constant(''))();
  BoolColumn get isDeleted             => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt          => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, quotationNo, quotationDate};
}

@DataClassName('SalesQuotationLineCacheEntry')
class SalesQuotationLinesCache extends Table {
  TextColumn get clientId             => text()();
  TextColumn get companyId            => text()();
  TextColumn get quotationNo          => text()();
  TextColumn get quotationDate        => text()();
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
  RealColumn get convertedQty         => real().withDefault(const Constant(0.0))();
  TextColumn get remarks              => text().withDefault(const Constant(''))();
  BoolColumn get isDeleted            => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt         => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, quotationNo, quotationDate, serialNo};
}

@DataClassName('SalesQuotationChargeLineCacheEntry')
class SalesQuotationChargeLinesCache extends Table {
  TextColumn get clientId          => text()();
  TextColumn get companyId         => text()();
  TextColumn get quotationNo       => text()();
  TextColumn get quotationDate     => text()();
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
  Set<Column> get primaryKey => {clientId, companyId, quotationNo, quotationDate, serialNo};
}
