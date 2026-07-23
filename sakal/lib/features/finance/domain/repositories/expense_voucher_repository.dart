abstract class ExpenseVoucherRepository {
  Future<List<Map<String, dynamic>>> listVouchers({
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
    required String transNo,
  });

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String transNo,
    required String transDate,
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
    required String locationId,
    required String transNo,
    required String transDate,
    required String approvedBy,
  });

  /// Client-side tax PREVIEW only — see expense_voucher_remote_ds.dart.
  Future<Map<String, List<String>>> getTaxGroupMemberTaxIds(List<String> groupIds);

  Future<Map<String, double>> getTaxRatesByIds({
    required List<String> taxIds,
    required String asOfDate,
  });

  Future<Map<String, bool>> getTaxWithholdingFlags(List<String> taxIds);

  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String transNo,
  });

  /// Offline: cache a just-saved DRAFT locally so it's visible while
  /// still queued (no-op on Web / when offline caching is unavailable).
  Future<void> cacheVoucherLocally({
    required String effectiveTransNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
  });
}
