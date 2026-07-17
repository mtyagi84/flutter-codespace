import 'package:drift/drift.dart';

/// Per-product UOM/barcode variants (rim_product_uom) — a product's
/// conversion factors and pack/piece-level barcodes. Not modeled via
/// GenericLookupCache because a barcode-scan lookup needs an indexed
/// `WHERE barcode = ?` query, which a raw-JSON-per-id blob can't do without
/// decoding every row client-side.
@DataClassName('ProductUomCacheEntry')
class ProductUomCache extends Table {
  TextColumn get productId         => text()();
  TextColumn get uomId             => text()();
  RealColumn get conversionFactor  => real().withDefault(const Constant(1))();
  BoolColumn get isBaseUom         => boolean().withDefault(const Constant(false))();
  TextColumn get barcode           => text().nullable()();
  TextColumn get uomDescription    => text().withDefault(const Constant(''))();
  DateTimeColumn get cachedAt      => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {productId, uomId};
}
