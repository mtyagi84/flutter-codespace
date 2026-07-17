abstract class SalesInvoiceRepository {
  Future<List<Map<String, dynamic>>> listInvoices({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    String? saleType,
    int     limit  = 50,
    int     offset = 0,
  });

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    String? invoiceDate,
  });

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  });

  Future<List<Map<String, dynamic>>> getCharges({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  });

  Future<List<Map<String, dynamic>>> getAdditionalCharges({
    required String clientId,
    required String companyId,
  });

  Future<List<Map<String, dynamic>>> getQuotationCharges({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
  });

  Future<List<Map<String, dynamic>>> getOrderCharges({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  });

  Future<List<Map<String, dynamic>>> getLineBatchAllocations({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  });

  Future<List<Map<String, dynamic>>> getLineSerialAllocations({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  });

  // ── Manager Review — online-only, no local fallback ───────────────────────

  Future<List<Map<String, dynamic>>> listDraftInvoicesForReview({
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

  // ── Against-Quotation / Against-Order — online-only ───────────────────────

  Future<List<Map<String, dynamic>>> getInvoiceableQuotations({
    required String clientId,
    required String companyId,
    String? search,
  });

  Future<List<Map<String, dynamic>>> getInvoiceableOrders({
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

  Future<Map<String, dynamic>?> getOrderHeader({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  });

  Future<List<Map<String, dynamic>>> getOrderLines({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
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

  Future<Map<String, dynamic>?> getUserSalesControls({
    required String clientId,
    required String companyId,
    required String userId,
  });

  Future<Map<String, dynamic>?> getQuickInvoiceSetup({
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

  /// Online-only — verifies a supervisor's credentials + discount
  /// eligibility server-side in one atomic call.
  Future<Map<String, dynamic>> verifyDiscountOverride({
    required String clientId,
    required String companyId,
    required String username,
    required String password,
    required double requestedDiscountPercent,
  });

  // ── Shared pickers ────────────────────────────────────────────────────────

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
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required String userId,
  });

  /// Caches an invoice locally for offline read-back/print. Called after
  /// every online save and on every offline save (Direct mode only —
  /// before enqueue).
  Future<void> cacheInvoiceLocally({
    required String effectiveInvoiceNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
  });

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
    required String approvedBy,
  });

  Future<void> cancel({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
    required String reason,
    required String userId,
  });
}
