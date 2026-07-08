abstract class OpeningStockRepository {
  Future<List<Map<String, dynamic>>> listOpeningStocks({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  });

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String openingNo,
    String? openingDate,
  });

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String openingNo,
    required String openingDate,
  });

  Future<List<Map<String, dynamic>>> getLocations({
    required String clientId,
    required String companyId,
  });

  Future<List<Map<String, dynamic>>> getProductsForPicker({
    required String clientId,
    required String companyId,
    String? search,
  });

  /// Resolves a scanned code to a product. Tries barcode first
  /// (rim_product_uom.barcode); if [tryPartNumber] is true and barcode
  /// misses, falls back to rim_products.part_number.
  Future<Map<String, dynamic>?> getProductByCode({
    required String clientId,
    required String companyId,
    required String code,
    required bool tryPartNumber,
  });

  /// Current on-hand quantity/cost for a product at this location — used
  /// only as a UX hint next to the line (the real
  /// OPENING_STOCK_ALREADY_ESTABLISHED guard is server-side, at Approve).
  Future<Map<String, dynamic>?> getCurrentStockAndCost({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  });

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required String userId,
  });

  /// Caches an entry locally for offline read-back. Called after every
  /// online save and on every offline save (before enqueue).
  Future<void> cacheOpeningStockLocally({
    required String effectiveOpeningNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
  });

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String openingNo,
    required String openingDate,
    required String approvedBy,
  });
}
