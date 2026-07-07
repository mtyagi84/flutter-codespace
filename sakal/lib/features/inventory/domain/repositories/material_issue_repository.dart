abstract class MaterialIssueRepository {
  Future<List<Map<String, dynamic>>> listIssues({
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
    required String issueNo,
    String? issueDate,
  });

  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String issueNo,
  });

  Future<List<Map<String, dynamic>>> getPostedVoucherLines({
    required String clientId,
    required String companyId,
    required String voucherNo,
    required String voucherDate,
  });

  Future<List<Map<String, dynamic>>> getFulfillableRequisitions({
    required String clientId,
    required String companyId,
    required String locationId,
  });

  Future<List<Map<String, dynamic>>> getRequisitionLines({
    required String clientId,
    required String companyId,
    required String requisitionNo,
    required String requisitionDate,
  });

  Future<num> getBatchBalance({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
    required String batchNo,
  });

  Future<List<Map<String, dynamic>>> getAvailableBatches({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  });

  Future<List<Map<String, dynamic>>> getAvailableSerials({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  });

  Future<List<Map<String, dynamic>>> getIssueLineBatches({
    required String clientId,
    required String companyId,
    required String issueNo,
    required String issueDate,
    required int    lineSerial,
  });

  Future<List<Map<String, dynamic>>> getIssueLineSerials({
    required String clientId,
    required String companyId,
    required String issueNo,
    required String issueDate,
    required int    lineSerial,
  });

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required String userId,
  });

  /// Caches an issue locally for offline read-back. Called after every
  /// online save and on every offline save (before enqueue).
  Future<void> cacheIssueLocally({
    required String effectiveIssueNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
  });

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String issueNo,
    required String issueDate,
    required String approvedBy,
  });
}
