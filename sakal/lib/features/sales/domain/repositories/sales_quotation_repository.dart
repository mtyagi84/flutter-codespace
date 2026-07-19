abstract class SalesQuotationRepository {
  Future<List<Map<String, dynamic>>> listQuotations({
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
    required String quotationNo,
    String? quotationDate,
  });

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
  });

  Future<List<Map<String, dynamic>>> getCharges({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
  });

  Future<Map<String, dynamic>?> getCustomerDetails({required String customerId});

  Future<List<Map<String, dynamic>>> getUsersForAutocomplete({
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

  Future<List<Map<String, dynamic>>> getTaxGroups({
    required String clientId,
    required String companyId,
  });

  Future<Map<String, List<String>>> getTaxGroupMemberTaxIds(List<String> groupIds);

  Future<Map<String, double>> getTaxRatesByIds({
    required List<String> taxIds,
    required String asOfDate,
  });

  Future<List<Map<String, dynamic>>> getAdditionalCharges({
    required String clientId,
    required String companyId,
  });

  Future<double?> getExchangeRate({
    required String companyId,
    required String locationId,
    required String fromCurrency,
    required String toCurrency,
    required String rateDate,
  });

  Future<Map<String, dynamic>?> getActivePrice({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
    required String uomId,
    required String? customerId,
    required String asOfDate,
    required String currencyCode,
  });

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> charges,
    required String userId,
  });

  /// Caches a quotation locally for offline read-back. Called after every
  /// online save and on every offline save (before enqueue).
  Future<void> cacheQuotationLocally({
    required String effectiveQuotationNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> charges,
  });

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
    required String approvedBy,
  });

  Future<void> updateStatus({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
    required String newStatus,
    required String userId,
  });
}
