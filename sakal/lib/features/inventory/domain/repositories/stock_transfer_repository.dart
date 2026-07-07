abstract class StockTransferRepository {
  Future<List<Map<String, dynamic>>> listTransfers({
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
    required String transferNo,
    String? transferDate,
  });

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String transferNo,
    required String transferDate,
  });

  Future<List<Map<String, dynamic>>> getCharges({
    required String clientId,
    required String companyId,
    required String transferNo,
    required String transferDate,
  });

  Future<List<Map<String, dynamic>>> getLocations({
    required String clientId,
    required String companyId,
  });

  Future<String> getInterLocationModel({
    required String clientId,
    required String companyId,
  });

  Future<List<Map<String, dynamic>>> getFulfillableRequests({
    required String clientId,
    required String companyId,
    required String fromLocationId,
  });

  Future<List<Map<String, dynamic>>> getRequestLines({
    required String clientId,
    required String companyId,
    required String requestNo,
    required String requestDate,
  });

  Future<List<Map<String, dynamic>>> getProductsForPicker({
    required String clientId,
    required String companyId,
    String? search,
  });

  Future<List<Map<String, dynamic>>> getAdditionalCharges({
    required String clientId,
    required String companyId,
  });

  Future<List<Map<String, dynamic>>> getAvailableBatches({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  });

  Future<List<Map<String, dynamic>>> getAvailableSerials({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  });

  Future<List<Map<String, dynamic>>> getTransferLineBatches({
    required String clientId,
    required String companyId,
    required String transferNo,
    required String transferDate,
    required int    lineSerial,
  });

  Future<List<Map<String, dynamic>>> getTransferLineSerials({
    required String clientId,
    required String companyId,
    required String transferNo,
    required String transferDate,
    required int    lineSerial,
  });

  Future<Map<String, num>> getCostPrices({
    required String clientId,
    required String companyId,
    required String locationId,
    required List<String> productIds,
  });

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required List<Map<String, dynamic>> charges,
    required String userId,
  });

  /// Caches a transfer locally for offline read-back. Called after every
  /// online save and on every offline save (before enqueue).
  Future<void> cacheTransferLocally({
    required String effectiveTransferNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required List<Map<String, dynamic>> charges,
  });

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String transferNo,
    required String transferDate,
    required String approvedBy,
  });

  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String transferNo,
  });

  Future<List<Map<String, dynamic>>> getPostedVoucherLines({
    required String clientId,
    required String companyId,
    required String voucherNo,
    required String voucherDate,
  });
}
