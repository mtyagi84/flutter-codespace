import 'package:drift/drift.dart';
import '../app_database.dart';

/// Local datasource for [ProductUomCache] — per-product UOM/barcode
/// variants and conversion factors (rim_product_uom).
class ProductUomLocalDs {
  final AppDatabase _db;
  ProductUomLocalDs(this._db);

  // Offline counterpart of price_master_remote_ds.dart's getProductUoms
  // fallback — see that file for the full writeup. rim_product_uom only
  // holds ADDITIONAL pack sizes, never auto-populated for a product's own
  // base UOM, so ProductUomCache can be legitimately empty for a product
  // that still has a perfectly valid cached base_uom_id.
  Future<List<Map<String, dynamic>>> getForProduct(String productId) async {
    final rows = await (_db.select(_db.productUomCache)
          ..where((t) => t.productId.equals(productId))
          ..orderBy([(t) => OrderingTerm.desc(t.isBaseUom)]))
        .get();
    if (rows.isNotEmpty) return rows.map(_toMap).toList();

    final product = await (_db.select(_db.productsCache)
          ..where((t) => t.id.equals(productId)))
        .getSingleOrNull();
    final baseUomId = product?.baseUomId;
    if (baseUomId == null) return [];
    final uom = await (_db.select(_db.commonMastersCache)
          ..where((t) => t.id.equals(baseUomId)))
        .getSingleOrNull();
    return [
      {
        'uom_id': baseUomId,
        'conversion_factor': 1.0,
        'is_base_uom': true,
        'barcode': null,
        'uom': {'description': uom?.description ?? ''},
      },
    ];
  }

  /// Barcode-scan resolution — mirrors the remote `getProductByCode`'s
  /// first branch (rim_product_uom.barcode match), joined back to the
  /// product itself.
  Future<Map<String, dynamic>?> getByBarcode(String barcode) async {
    final row = await (_db.select(_db.productUomCache)
          ..where((t) => t.barcode.equals(barcode)))
        .getSingleOrNull();
    if (row == null) return null;
    final product = await (_db.select(_db.productsCache)
          ..where((t) => t.id.equals(row.productId))
          ..where((t) => t.isDeleted.equals(false))
          ..where((t) => t.isActive.equals(true)))
        .getSingleOrNull();
    if (product == null) return null;
    return {
      'id': product.id,
      'product_code': product.productCode,
      'product_name': product.productName,
      'base_uom_id': product.baseUomId,
      'tracking_type': product.trackingType,
      'sales_tax_group_id': product.salesTaxGroupId,
      'matched_uom_id': row.uomId,
      'matched_uom_conversion_factor': row.conversionFactor,
      'matched_uom_label': row.uomDescription,
    };
  }

  Future<void> upsert(List<Map<String, dynamic>> rows) async {
    await _db.batch((batch) {
      for (final r in rows) {
        batch.insert(
          _db.productUomCache,
          ProductUomCacheCompanion.insert(
            productId: r['product_id'] as String,
            uomId: r['uom_id'] as String,
            conversionFactor: Value((r['conversion_factor'] as num?)?.toDouble() ?? 1),
            isBaseUom: Value(r['is_base_uom'] as bool? ?? false),
            barcode: Value(r['barcode'] as String?),
            uomDescription: Value((r['uom'] as Map?)?['description'] as String? ?? r['uom_description'] as String? ?? ''),
            cachedAt: Value(DateTime.now()),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  Map<String, dynamic> _toMap(ProductUomCacheEntry e) => {
        'uom_id': e.uomId,
        'conversion_factor': e.conversionFactor,
        'is_base_uom': e.isBaseUom,
        'barcode': e.barcode,
        'uom': {'description': e.uomDescription},
      };
}
