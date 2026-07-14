import 'package:drift/drift.dart';

/// Offline cache for Sales Orders — mirrors the header/lines/charges shape
/// saved via fn_save_sales_order. Business composite key (client_id,
/// company_id, order_no, order_date) — same shape as SalesQuotationsCache's
/// (quotation_no, quotation_date) key. locationId is a plain
/// display/editable column only, not part of the key (086_sales_order.sql:
/// location_id lives on the header as a plain column, same shape as Sales
/// Quotation/GRN/Material Requisition).
@DataClassName('SalesOrderCacheEntry')
class SalesOrdersCache extends Table {
  TextColumn get clientId              => text()();
  TextColumn get companyId             => text()();
  TextColumn get locationId            => text().withDefault(const Constant(''))();
  TextColumn get locationName          => text().withDefault(const Constant(''))();
  TextColumn get orderNo               => text()();
  TextColumn get orderDate             => text()(); // 'YYYY-MM-DD'
  TextColumn get orderMode             => text().withDefault(const Constant('DIRECT'))(); // DIRECT | AGAINST_QUOTATION
  TextColumn get sourceQuotationNo     => text().withDefault(const Constant(''))();
  TextColumn get sourceQuotationDate   => text().withDefault(const Constant(''))();
  TextColumn get customerId            => text()();
  TextColumn get customerCode          => text().withDefault(const Constant(''))();
  TextColumn get customerName          => text().withDefault(const Constant(''))();
  TextColumn get customerPoRef         => text().withDefault(const Constant(''))();
  TextColumn get salesPersonId         => text().withDefault(const Constant(''))();
  TextColumn get salesPersonName       => text().withDefault(const Constant(''))();
  TextColumn get orderCurrencyId       => text()();
  TextColumn get orderCurrencyCode     => text().withDefault(const Constant(''))();
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
  Set<Column> get primaryKey => {clientId, companyId, orderNo, orderDate};
}

@DataClassName('SalesOrderLineCacheEntry')
class SalesOrderLinesCache extends Table {
  TextColumn get clientId                    => text()();
  TextColumn get companyId                   => text()();
  TextColumn get orderNo                     => text()();
  TextColumn get orderDate                   => text()();
  IntColumn  get serialNo                    => integer()();
  TextColumn get productId                   => text()();
  TextColumn get productCode                 => text().withDefault(const Constant(''))();
  TextColumn get productName                 => text().withDefault(const Constant(''))();
  TextColumn get itemDescription             => text().withDefault(const Constant(''))();
  TextColumn get barcode                     => text().withDefault(const Constant(''))();
  TextColumn get uomId                       => text()();
  TextColumn get uomLabel                    => text().withDefault(const Constant(''))();
  RealColumn get uomConversionFactor         => real().withDefault(const Constant(1.0))();
  RealColumn get qtyPack                     => real().withDefault(const Constant(0.0))();
  RealColumn get qtyLoose                    => real().withDefault(const Constant(0.0))();
  RealColumn get baseQty                     => real().withDefault(const Constant(0.0))();
  RealColumn get rate                        => real().withDefault(const Constant(0.0))();
  TextColumn get priceSource                 => text().withDefault(const Constant('PRICE_MASTER'))();
  TextColumn get priceOverrideReason         => text().withDefault(const Constant(''))();
  RealColumn get grossAmount                 => real().withDefault(const Constant(0.0))();
  RealColumn get discountPercent             => real().withDefault(const Constant(0.0))();
  RealColumn get discountAmount              => real().withDefault(const Constant(0.0))();
  TextColumn get taxGroupId                  => text().withDefault(const Constant(''))();
  TextColumn get taxGroupName                => text().withDefault(const Constant(''))();
  RealColumn get taxAmount                   => real().withDefault(const Constant(0.0))();
  RealColumn get finalAmount                 => real().withDefault(const Constant(0.0))();
  RealColumn get baseAmount                  => real().withDefault(const Constant(0.0))();
  RealColumn get localAmount                 => real().withDefault(const Constant(0.0))();
  RealColumn get chargeAmount                => real().withDefault(const Constant(0.0))();
  RealColumn get landedAmount                => real().withDefault(const Constant(0.0))();
  RealColumn get deliveredQty                => real().withDefault(const Constant(0.0))();
  IntColumn  get sourceQuotationLineSerial   => integer().nullable()();
  // Cost/margin — populated only when session.canViewCostPrice is true;
  // never fetched otherwise (see prospect/sales controls design — hidden
  // by never fetching, not just by hiding a UI column).
  RealColumn get costPrice                   => real().nullable()();
  TextColumn get remarks                     => text().withDefault(const Constant(''))();
  BoolColumn get isDeleted                   => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt                => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, orderNo, orderDate, serialNo};
}

@DataClassName('SalesOrderChargeLineCacheEntry')
class SalesOrderChargeLinesCache extends Table {
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
