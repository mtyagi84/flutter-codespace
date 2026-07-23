abstract class CashReceiptRepository {
  Future<List<Map<String, dynamic>>> listReceipts({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int limit = 50,
    int offset = 0,
  });

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String receiptNo,
  });

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String receiptNo,
    required String receiptDate,
  });

  Future<Map<String, dynamic>?> getQuickInvoiceSetup({
    required String clientId,
    required String companyId,
    required String userId,
  });

  Future<List<Map<String, dynamic>>> getCustomersWithPendingBills({
    required String clientId,
    required String companyId,
    required String locationId,
    String? search,
  });

  Future<List<Map<String, dynamic>>> getPendingBills({
    required String companyId,
    required String locationId,
    required String accountId,
  });

  Future<Map<String, dynamic>> getCompanyCurrencies({required String companyId});

  Future<double?> getExchangeRate({
    required String companyId,
    required String locationId,
    required String fromCurrency,
    required String toCurrency,
    required String rateDate,
  });

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required String userId,
  });

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String receiptNo,
    required String receiptDate,
    required String approvedBy,
  });

  Future<List<Map<String, dynamic>>> listDraftReceiptsForReview({
    required String clientId,
    required String companyId,
    required String locationId,
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

  Future<List<Map<String, dynamic>>> getUsersForAutocomplete({
    required String clientId,
    required String companyId,
  });

  /// Offline: cache a just-saved DRAFT locally so it's visible while
  /// still queued (no-op on Web / when offline caching is unavailable).
  Future<void> cacheReceiptLocally({
    required String effectiveReceiptNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
  });
}
