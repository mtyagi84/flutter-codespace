abstract class StockAdjustmentRepository {
  Future<List<Map<String, dynamic>>> listAdjustments({
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
    required String adjustmentNo,
    String? adjustmentDate,
  });

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String adjustmentNo,
    required String adjustmentDate,
  });

  Future<List<Map<String, dynamic>>> getLineBatches({
    required String clientId,
    required String companyId,
    required String adjustmentNo,
    required String adjustmentDate,
    required int    lineSerial,
  });

  Future<List<Map<String, dynamic>>> getLineSerials({
    required String clientId,
    required String companyId,
    required String adjustmentNo,
    required String adjustmentDate,
    required int    lineSerial,
  });

  Future<List<Map<String, dynamic>>> getLocations({
    required String clientId,
    required String companyId,
  });

  Future<List<Map<String, dynamic>>> getReasons({
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

  /// Current on-hand quantity for a product at this location — used only
  /// as the system_qty display hint next to whatever the user enters, and
  /// pre-filled on the row when a product is first selected.
  Future<num> getCurrentStock({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
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

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required String userId,
  });

  /// Caches an adjustment locally for offline read-back. Called after every
  /// online save and on every offline save (before enqueue).
  Future<void> cacheAdjustmentLocally({
    required String effectiveAdjustmentNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
  });

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String adjustmentNo,
    required String adjustmentDate,
    required String approvedBy,
  });

  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String adjustmentNo,
  });

  Future<List<Map<String, dynamic>>> getPostedVoucherLines({
    required String clientId,
    required String companyId,
    required String voucherNo,
    required String voucherDate,
  });
}
