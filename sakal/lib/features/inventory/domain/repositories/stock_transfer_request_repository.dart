abstract class StockTransferRequestRepository {
  Future<List<Map<String, dynamic>>> listRequests({
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
    required String requestNo,
    String? requestDate,
  });

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String requestNo,
    required String requestDate,
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

  Future<Map<String, dynamic>?> getProductByBarcode({
    required String clientId,
    required String companyId,
    required String barcode,
  });

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required String userId,
  });

  /// Caches a request locally for offline read-back. Called after every
  /// online save and on every offline save (before enqueue).
  Future<void> cacheRequestLocally({
    required String effectiveRequestNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
  });

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String requestNo,
    required String requestDate,
    required String approvedBy,
  });
}
