abstract class SalesDeliveryRepository {
  Future<List<Map<String, dynamic>>> listDeliveries({
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
    required String deliveryNo,
    String? deliveryDate,
  });

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String deliveryNo,
    required String deliveryDate,
  });

  Future<List<Map<String, dynamic>>> getPendingDeliveryInvoices({
    required String clientId,
    required String companyId,
    String? search,
  });

  Future<Map<String, dynamic>?> getDeliveryStatusForInvoice({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  });

  Future<List<Map<String, dynamic>>> getDeliveryStatusForInvoices({
    required String clientId,
    required String companyId,
    required List<String> invoiceNos,
  });

  Future<List<Map<String, dynamic>>> getInvoiceLines({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  });

  Future<List<Map<String, dynamic>>> getBatchStockBalance({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  });

  Future<List<Map<String, dynamic>>> getSerialStockStatus({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  });

  Future<List<Map<String, dynamic>>> getDeliveryLineBatches({
    required String clientId,
    required String companyId,
    required String deliveryNo,
    required String deliveryDate,
  });

  Future<List<Map<String, dynamic>>> getDeliveryLineSerials({
    required String clientId,
    required String companyId,
    required String deliveryNo,
    required String deliveryDate,
  });

  Future<List<Map<String, dynamic>>> getCustomerDeliveryLocations({
    required String clientId,
    required String companyId,
    required String customerId,
  });

  Future<String> saveCustomerDeliveryLocation({
    required Map<String, dynamic> payload,
    required bool isNew,
    required String userId,
  });

  Future<void> deleteCustomerDeliveryLocation({required String id, required String userId});

  Future<Map<String, dynamic>?> getTransportDetails({
    required String clientId,
    required String companyId,
    required String deliveryNo,
    required String deliveryDate,
  });

  Future<List<Map<String, dynamic>>> getUsersForAutocomplete({
    required String clientId,
    required String companyId,
  });

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    Map<String, dynamic>? transport,
    required String userId,
  });

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String deliveryNo,
    required String deliveryDate,
    required String approvedBy,
  });

  Future<List<Map<String, dynamic>>> listDraftDeliveriesForReview({
    required String clientId,
    required String companyId,
    required String locationId,
  });

  Future<Map<String, dynamic>?> getStockPreview({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  });

  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String deliveryNo,
  });

  Future<List<Map<String, dynamic>>> getPostedVoucherLines({
    required String clientId,
    required String companyId,
    required String voucherNo,
    required String voucherDate,
  });

  /// Offline: cache a just-saved DRAFT locally so it's visible while
  /// still queued (no-op on Web / when offline caching is unavailable).
  Future<void> cacheDeliveryLocally({
    required String effectiveDeliveryNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
  });
}
