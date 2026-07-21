abstract class SalesReturnRepository {
  Future<List<Map<String, dynamic>>> listReturns({
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
    required String returnNo,
    String? returnDate,
  });

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
  });

  Future<List<Map<String, dynamic>>> getCharges({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
  });

  Future<List<Map<String, dynamic>>> getApprovedInvoices({
    required String clientId,
    required String companyId,
    String? search,
  });

  Future<List<Map<String, dynamic>>> getInvoiceLines({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  });

  Future<List<Map<String, dynamic>>> getInvoiceCharges({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  });

  Future<List<Map<String, dynamic>>> getAlreadyReturnedByLine({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  });

  Future<List<Map<String, dynamic>>> getInvoiceLineBatches({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
    required int    lineSerial,
  });

  Future<List<Map<String, dynamic>>> getInvoiceLineSerials({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
    required int    lineSerial,
  });

  Future<List<Map<String, dynamic>>> getAlreadyReturnedBatches({
    required String clientId,
    required String companyId,
    required List<String> returnNos,
  });

  Future<List<Map<String, dynamic>>> getAlreadyReturnedSerials({
    required String clientId,
    required String companyId,
    required List<String> returnNos,
  });

  Future<List<Map<String, dynamic>>> getPriorReturnLineKeys({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  });

  Future<List<Map<String, dynamic>>> listDraftReturnsForReview({
    required String clientId,
    required String companyId,
    required String locationId,
  });

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required List<Map<String, dynamic>> charges,
    required String userId,
  });

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
    required String approvedBy,
  });

  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String returnNo,
  });

  Future<List<Map<String, dynamic>>> getPostedVoucherLines({
    required String clientId,
    required String companyId,
    required String voucherNo,
    required String voucherDate,
  });

  /// Offline: cache a just-saved DRAFT locally so it's visible while
  /// still queued (no-op on Web / when offline caching is unavailable).
  Future<void> cacheReturnLocally({
    required String effectiveReturnNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
  });
}
