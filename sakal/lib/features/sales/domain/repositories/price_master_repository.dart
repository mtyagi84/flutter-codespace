abstract class PriceMasterRepository {
  Future<List<Map<String, dynamic>>> listBatches({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    String? priceType,
    String? locationId,
    int     limit  = 50,
    int     offset = 0,
  });

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String entryNo,
    String? entryDate,
  });

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String entryNo,
    required String entryDate,
  });

  Future<List<Map<String, dynamic>>> getProductsForPicker({
    required String clientId,
    required String companyId,
    String? search,
  });

  Future<List<Map<String, dynamic>>> getProductUoms(String productId);

  /// Below-cost reason picker (rim_common_masters, type_key
  /// 'PRICE_BELOW_COST_REASON').
  Future<List<Map<String, dynamic>>> getReasons({
    required String clientId,
    required String companyId,
  });

  /// Barcode-first / part-number-fallback product lookup for the header
  /// scan field.
  Future<Map<String, dynamic>?> getProductByCode({
    required String clientId,
    required String companyId,
    required String code,
    required bool tryPartNumber,
  });

  /// rim_product_location's current cost_price/cost_price_specific at a
  /// Location — feeds the three-way Cost Price display rule.
  Future<Map<String, dynamic>?> getProductLocationCost({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  });

  /// Rate to Base/Local, via fn_get_exchange_rate (SELLING rate).
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

  /// Caches a batch locally for offline read-back. Called after every online
  /// save and on every offline save (before enqueue).
  Future<void> cacheBatchLocally({
    required String effectiveEntryNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
  });

  /// Online-only — needs live numbering/uniqueness enforcement and must be
  /// visible to other users immediately, same convention as every other
  /// module's Approve gate.
  Future<void> approve({
    required String clientId,
    required String companyId,
    required String entryNo,
    required String entryDate,
    required String approvedBy,
  });
}
