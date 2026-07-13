import 'package:drift/drift.dart';

/// Offline cache for Sales Price Master batches — mirrors the header/lines
/// shape saved via fn_save_price_master_batch. Business composite key
/// (client_id, company_id, entry_no, entry_date) — same shape as Purchase
/// Order's (order_no, order_date) key.
///
/// REVISED (see docs/screens/sales_price_master.md): pricing is
/// LOCATION-WISE, not company-wide — locationId/locationName and the
/// batch's own priceCurrencyId/currencyCode/rateToBase/rateToLocal were
/// added here. An earlier draft of this cache had no location column at
/// all; that draft was never shipped.
@DataClassName('PriceMasterHeaderCacheEntry')
class PriceMasterHeadersCache extends Table {
  TextColumn get clientId       => text()();
  TextColumn get companyId      => text()();
  TextColumn get entryNo        => text()();
  TextColumn get entryDate      => text()(); // 'YYYY-MM-DD'
  TextColumn get locationId     => text().withDefault(const Constant(''))();
  TextColumn get locationName   => text().withDefault(const Constant(''))();
  TextColumn get priceType      => text().withDefault(const Constant('GENERIC'))();
  TextColumn get customerId     => text().withDefault(const Constant(''))(); // empty = GENERIC
  TextColumn get customerCode   => text().withDefault(const Constant(''))();
  TextColumn get customerName   => text().withDefault(const Constant(''))();
  TextColumn get effectiveDate  => text().withDefault(const Constant(''))();
  TextColumn get priceCurrencyId => text().withDefault(const Constant(''))();
  TextColumn get currencyCode   => text().withDefault(const Constant(''))();
  RealColumn get rateToBase     => real().withDefault(const Constant(1.0))();
  RealColumn get rateToLocal    => real().withDefault(const Constant(1.0))();
  TextColumn get status         => text().withDefault(const Constant('DRAFT'))();
  TextColumn get approvedBy     => text().withDefault(const Constant(''))();
  TextColumn get approvedAt     => text().withDefault(const Constant(''))();
  TextColumn get remarks        => text().withDefault(const Constant(''))();
  IntColumn  get lineCount      => integer().withDefault(const Constant(0))();
  BoolColumn get isDeleted      => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt   => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, entryNo, entryDate};
}

@DataClassName('PriceMasterLineCacheEntry')
class PriceMasterLinesCache extends Table {
  TextColumn get clientId             => text()();
  TextColumn get companyId            => text()();
  TextColumn get entryNo              => text()();
  TextColumn get entryDate            => text()();
  IntColumn  get serialNo             => integer()();
  TextColumn get productId            => text()();
  TextColumn get productCode          => text().withDefault(const Constant(''))();
  TextColumn get productName          => text().withDefault(const Constant(''))();
  TextColumn get uomId                => text()();
  TextColumn get uomLabel             => text().withDefault(const Constant(''))();
  RealColumn get uomConversionFactor  => real().withDefault(const Constant(1.0))();
  // What was actually scanned to build/identify this line — audit only,
  // empty if the line was added via the Product Autocomplete instead.
  TextColumn get barcode              => text().withDefault(const Constant(''))();
  // Snapshot, in the header's own currency — see the three-way currency
  // rule in docs/screens/sales_price_master.md §4. Client-computed, never
  // re-derived by the server.
  RealColumn get costPrice            => real().withDefault(const Constant(0.0))();
  // Convenience/audit value, markup-on-cost — nullable (disabled client-side
  // whenever costPrice is 0/unresolved).
  RealColumn get marginPercent        => real().nullable()();
  RealColumn get sellingPrice         => real().withDefault(const Constant(0.0))();
  TextColumn get belowCostReasonId    => text().withDefault(const Constant(''))();
  TextColumn get belowCostReasonName  => text().withDefault(const Constant(''))();
  // No taxGroupId/taxGroupName — rim_products.sales_tax_group_id is
  // already the authoritative link; a future Sales Order/Invoice resolves
  // tax group from the product itself, not from this cached line.
  BoolColumn get isTaxInclusive       => boolean().withDefault(const Constant(false))();
  TextColumn get remarks              => text().withDefault(const Constant(''))();
  BoolColumn get isDeleted            => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt         => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, entryNo, entryDate, serialNo};
}
