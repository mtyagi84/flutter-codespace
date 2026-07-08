abstract class StockCountReviewRepository {
  Future<List<Map<String, dynamic>>> listReviews({
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
    required String reviewNo,
    String? reviewDate,
  });

  Future<List<Map<String, dynamic>>> getSources({
    required String clientId,
    required String companyId,
    required String reviewNo,
    required String reviewDate,
  });

  Future<List<Map<String, dynamic>>> getLocations({
    required String clientId,
    required String companyId,
  });

  Future<List<Map<String, dynamic>>> getReasons({
    required String clientId,
    required String companyId,
  });

  /// SUBMITTED Stock Counts at a location, available to be picked into a
  /// review (or already reserved by THIS review, when editing a draft).
  Future<List<Map<String, dynamic>>> getSubmittedCounts({
    required String clientId,
    required String companyId,
    required String locationId,
    String? currentReviewNo,
  });

  /// Every line of a submitted count — used for the per-source drill-down
  /// on the variance grid (cheap client-side join over already-picked
  /// sources, never a fresh remote call per drill-down click).
  Future<List<Map<String, dynamic>>> getCountLines({
    required String clientId,
    required String companyId,
    required String countNo,
    required String countDate,
  });

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> sourceRefs,
    required String userId,
  });

  /// fn_compute_stock_count_variance — the same function Approve uses, so
  /// the preview grid is guaranteed to match what gets posted.
  Future<List<Map<String, dynamic>>> computeVariance({
    required String clientId,
    required String companyId,
    required String reviewNo,
    required String reviewDate,
  });

  /// Returns the posted Stock Adjustment number.
  Future<String> approve({
    required String clientId,
    required String companyId,
    required String reviewNo,
    required String reviewDate,
    required String approvedBy,
  });
}
