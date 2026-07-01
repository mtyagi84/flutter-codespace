import 'dart:convert';
import 'package:drift/drift.dart';
import '../../../../core/database/app_database.dart';
import '../models/product_model.dart';

class ProductsLocalDs {
  final AppDatabase _db;
  ProductsLocalDs(this._db);

  Future<List<ProductModel>> getProducts({
    required String clientId,
    required String companyId,
    String? search,
    bool?   isActive,
    int     limit  = 50,
    int     offset = 0,
  }) async {
    final q = _db.select(_db.productsCache)
      ..where((t) =>
          t.clientId.equals(clientId) &
          t.companyId.equals(companyId) &
          t.isDeleted.equals(false));
    if (isActive != null) {
      q.where((t) => t.isActive.equals(isActive));
    }
    q.orderBy([(t) => OrderingTerm.asc(t.productCode)]);
    q.limit(limit, offset: offset);
    final rows = await q.get();
    // Client-side search — offline list is small enough
    if (search != null && search.isNotEmpty) {
      final lower = search.toLowerCase();
      return rows
          .where((r) =>
              r.productCode.toLowerCase().contains(lower) ||
              r.productName.toLowerCase().contains(lower))
          .map(_toModel)
          .toList();
    }
    return rows.map(_toModel).toList();
  }

  Future<ProductModel?> getProduct(String id) async {
    final row = await (_db.select(_db.productsCache)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _toModel(row);
  }

  Future<void> upsertProducts(List<ProductModel> products) async {
    await _db.batch((batch) {
      for (final p in products) {
        batch.insert(_db.productsCache, _toEntry(p),
            mode: InsertMode.insertOrReplace);
      }
    });
  }

  ProductCacheEntry _toEntry(ProductModel p) => ProductCacheEntry(
        id:                  p.id ?? '',
        clientId:            p.clientId,
        companyId:           p.companyId,
        productCode:         p.productCode,
        productName:         p.productName,
        productNature:       p.productNature,
        barcode:             p.barcode,
        partNumber:          p.partNumber,
        shortName:           p.shortName,
        description:         p.description,
        categoryId:          p.categoryId,
        brandId:             p.brandId,
        itemSizeId:          p.itemSizeId,
        itemColorId:         p.itemColorId,
        baseUomId:           p.baseUomId,
        standardCost:        p.standardCost,
        averageCost:         p.averageCost,
        lastPurchaseCost:    p.lastPurchaseCost,
        allowedCostVariance: p.allowedCostVariance,
        costCurrencyId:      p.costCurrencyId,
        salesTaxGroupId:     p.salesTaxGroupId,
        purchaseTaxGroupId:  p.purchaseTaxGroupId,
        hsnSacCode:          p.hsnSacCode,
        mainSupplierId:      p.mainSupplierId,
        leadTimeDays:        p.leadTimeDays,
        trackingType:        p.trackingType,
        isActive:            p.isActive,
        isDeleted:           p.isDeleted,
        isScalable:          p.isScalable,
        flagsJson:           jsonEncode(p.flags),
        sortOrder:           p.sortOrder,
        remarks:             p.remarks,
        categoryName:        p.categoryName,
        baseUomName:         p.baseUomName,
      );

  ProductModel _toModel(ProductCacheEntry e) {
    final rawFlags = jsonDecode(e.flagsJson) as Map<String, dynamic>? ?? {};
    return ProductModel(
      id:                   e.id,
      clientId:             e.clientId,
      companyId:            e.companyId,
      productCode:          e.productCode,
      productName:          e.productName,
      productNature:        e.productNature,
      barcode:              e.barcode,
      partNumber:           e.partNumber,
      shortName:            e.shortName,
      description:          e.description,
      categoryId:           e.categoryId,
      brandId:              e.brandId,
      itemSizeId:           e.itemSizeId,
      itemColorId:          e.itemColorId,
      baseUomId:            e.baseUomId,
      standardCost:         e.standardCost,
      averageCost:          e.averageCost,
      lastPurchaseCost:     e.lastPurchaseCost,
      allowedCostVariance:  e.allowedCostVariance,
      costCurrencyId:       e.costCurrencyId,
      salesTaxGroupId:      e.salesTaxGroupId,
      purchaseTaxGroupId:   e.purchaseTaxGroupId,
      hsnSacCode:           e.hsnSacCode,
      mainSupplierId:       e.mainSupplierId,
      leadTimeDays:         e.leadTimeDays,
      trackingType:         e.trackingType,
      isActive:             e.isActive,
      isDeleted:            e.isDeleted,
      isScalable:           e.isScalable,
      flags:                rawFlags.map((k, v) => MapEntry(k, (v as bool?) ?? false)),
      sortOrder:            e.sortOrder,
      remarks:              e.remarks,
      categoryName:         e.categoryName,
      baseUomName:          e.baseUomName,
    );
  }
}
