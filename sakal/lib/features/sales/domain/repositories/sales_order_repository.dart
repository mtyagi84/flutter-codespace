abstract class SalesOrderRepository {
  Future<List<Map<String, dynamic>>> listOrders({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    String? orderMode,
    int     limit  = 50,
    int     offset = 0,
  });

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String orderNo,
    String? orderDate,
  });

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  });

  Future<List<Map<String, dynamic>>> getCharges({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  });

  // ── Against-Quotation mode ────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getConvertibleQuotations({
    required String clientId,
    required String companyId,
    String? search,
  });

  Future<Map<String, dynamic>?> getQuotationHeader({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
  });

  Future<List<Map<String, dynamic>>> getQuotationLines({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
  });

  Future<List<Map<String, dynamic>>> getQuotationCharges({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
  });

  /// Online-only — creates a real rim_accounts row, updates the source
  /// quotation's customer_id/customer_type, and logs the conversion.
  Future<void> convertProspectToCustomer({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
    required Map<String, dynamic> account,
    String? notes,
    required String userId,
  });

  // ── Direct mode: price/discount governance ───────────────────────────────

  Future<Map<String, dynamic>?> getActivePrice({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
    required String uomId,
    required String customerId,
    required String asOfDate,
    required String currencyCode,
  });

  Future<List<Map<String, dynamic>>> getPaymentTerms({
    required String clientId,
    required String companyId,
  });

  Future<List<Map<String, dynamic>>> getIncoterms({
    required String clientId,
    required String companyId,
  });

  Future<Map<String, dynamic>?> getUserSalesControls({
    required String clientId,
    required String companyId,
    required String userId,
  });

  Future<Map<String, dynamic>?> getProductLocationCost({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  });

  // ── Shared pickers ────────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> getCustomerDetails({required String customerId});

  Future<List<Map<String, dynamic>>> getUsersForAutocomplete({
    required String clientId,
    required String companyId,
  });

  Future<List<Map<String, dynamic>>> getSalesExecutivesForPicker({
    required String clientId,
    required String companyId,
  });

  Future<List<Map<String, dynamic>>> getProductsForPicker({
    required String clientId,
    required String companyId,
    String? search,
  });

  Future<Map<String, dynamic>?> getProductByCode({
    required String clientId,
    required String companyId,
    required String code,
    required bool tryPartNumber,
  });

  Future<List<Map<String, dynamic>>> getProductUoms(String productId);

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

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> charges,
    required String userId,
  });

  /// Caches an order locally for offline read-back. Called after every
  /// online save and on every offline save (Direct mode only — before
  /// enqueue).
  Future<void> cacheOrderLocally({
    required String effectiveOrderNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> charges,
  });

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
    required String approvedBy,
  });

  Future<void> cancel({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
    required String reason,
    required String userId,
  });
}
