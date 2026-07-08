abstract class StockCountRepository {
  Future<List<Map<String, dynamic>>> listStockCounts({
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
    required String countNo,
    String? countDate,
  });

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String countNo,
    required String countDate,
  });

  Future<List<Map<String, dynamic>>> getLineBatches({
    required String clientId,
    required String companyId,
    required String countNo,
    required String countDate,
    required int    lineSerial,
  });

  Future<List<Map<String, dynamic>>> getLineSerials({
    required String clientId,
    required String companyId,
    required String countNo,
    required String countDate,
    required int    lineSerial,
  });

  Future<List<Map<String, dynamic>>> getLocations({
    required String clientId,
    required String companyId,
  });

  /// fn_stock_count_eligible_products — called ONCE when a new count is
  /// started; the returned set becomes the worksheet's fixed scope.
  Future<List<Map<String, dynamic>>> getEligibleProducts({
    required String clientId,
    required String companyId,
    String? categoryId,
    String? nature,
  });

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required String userId,
  });

  /// Caches an entry locally for offline read-back. Called after every
  /// online save and on every offline save (before enqueue).
  Future<void> cacheStockCountLocally({
    required String effectiveCountNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
  });

  Future<void> submit({
    required String clientId,
    required String companyId,
    required String countNo,
    required String countDate,
    required String userId,
  });
}
