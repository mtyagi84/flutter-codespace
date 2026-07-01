import 'package:drift/drift.dart';

@DataClassName('ProductCacheEntry')
class ProductsCache extends Table {
  // Identity
  TextColumn get id            => text()();
  TextColumn get clientId      => text()();
  TextColumn get companyId     => text()();
  TextColumn get productCode   => text()();
  TextColumn get productName   => text()();
  TextColumn get productNature => text().withDefault(const Constant('TRADING'))();
  TextColumn get barcode       => text().nullable()();
  TextColumn get partNumber    => text().nullable()();
  TextColumn get shortName     => text().nullable()();
  TextColumn get description   => text().nullable()();

  // Classification
  TextColumn get categoryId   => text().nullable()();
  TextColumn get brandId      => text().nullable()();
  TextColumn get itemSizeId   => text().nullable()();
  TextColumn get itemColorId  => text().nullable()();
  TextColumn get baseUomId    => text().nullable()();

  // Costing
  RealColumn get standardCost        => real().withDefault(const Constant(0))();
  RealColumn get averageCost         => real().withDefault(const Constant(0))();
  RealColumn get lastPurchaseCost    => real().withDefault(const Constant(0))();
  RealColumn get allowedCostVariance => real().withDefault(const Constant(0))();
  TextColumn get costCurrencyId      => text().nullable()();

  // Tax
  TextColumn get salesTaxGroupId    => text().nullable()();
  TextColumn get purchaseTaxGroupId => text().nullable()();
  TextColumn get hsnSacCode         => text().nullable()();

  // Supplier
  TextColumn get mainSupplierId => text().nullable()();
  IntColumn  get leadTimeDays   => integer().withDefault(const Constant(0))();

  // Tracking + status
  TextColumn get trackingType => text().withDefault(const Constant('NONE'))();
  BoolColumn get isActive     => boolean().withDefault(const Constant(true))();
  BoolColumn get isDeleted    => boolean().withDefault(const Constant(false))();
  BoolColumn get isScalable   => boolean().withDefault(const Constant(false))();

  // Business flags — stored as JSON string
  TextColumn get flagsJson => text().withDefault(const Constant('{}'))();

  // Misc
  IntColumn  get sortOrder => integer().withDefault(const Constant(0))();
  TextColumn get remarks   => text().nullable()();

  // Joined display names for list view
  TextColumn get categoryName => text().nullable()();
  TextColumn get baseUomName  => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
