abstract class StockReceiptRepository {
  Future<List<Map<String, dynamic>>> listReceipts({
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
    required String receiptNo,
    String? receiptDate,
  });

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String receiptNo,
    required String receiptDate,
  });

  Future<List<Map<String, dynamic>>> getReceivableTransfers({
    required String clientId,
    required String companyId,
    String? toLocationId,
  });

  Future<List<Map<String, dynamic>>> getTransferLines({
    required String clientId,
    required String companyId,
    required String transferNo,
    required String transferDate,
  });

  Future<List<Map<String, dynamic>>> getDispatchedBatches({
    required String clientId,
    required String companyId,
    required String transferNo,
    required String transferDate,
    required int    lineSerial,
  });

  Future<List<Map<String, dynamic>>> getDispatchedSerials({
    required String clientId,
    required String companyId,
    required String transferNo,
    required String transferDate,
    required int    lineSerial,
  });

  Future<List<Map<String, dynamic>>> getReceiptLineBatches({
    required String clientId,
    required String companyId,
    required String receiptNo,
    required String receiptDate,
    required int    lineSerial,
  });

  Future<List<Map<String, dynamic>>> getReceiptLineSerials({
    required String clientId,
    required String companyId,
    required String receiptNo,
    required String receiptDate,
    required int    lineSerial,
  });

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required String userId,
  });

  /// Caches a receipt locally for offline read-back. Called after every
  /// online save and on every offline save (before enqueue).
  Future<void> cacheReceiptLocally({
    required String effectiveReceiptNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
  });

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String receiptNo,
    required String receiptDate,
    required String approvedBy,
  });

  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String receiptNo,
  });

  Future<List<Map<String, dynamic>>> getPostedVoucherLines({
    required String clientId,
    required String companyId,
    required String voucherNo,
    required String voucherDate,
  });
}
