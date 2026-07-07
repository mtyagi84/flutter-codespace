abstract class MaterialRequisitionRepository {
  Future<List<Map<String, dynamic>>> listRequisitions({
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
    required String requisitionNo,
    String? requisitionDate,
  });

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String requisitionNo,
    required String requisitionDate,
  });

  Future<List<Map<String, dynamic>>> getLocationsForIssue({
    required String clientId,
    required String companyId,
  });

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

  Future<List<Map<String, dynamic>>> getDepartments({
    required String clientId,
    required String companyId,
  });

  Future<List<Map<String, dynamic>>> getConsumptionAreasForDepartment({
    required String clientId,
    required String companyId,
    required String departmentId,
  });

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required String userId,
  });

  /// Caches a requisition locally for offline read-back. Called after every
  /// online save and on every offline save (before enqueue).
  Future<void> cacheRequisitionLocally({
    required String effectiveRequisitionNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
  });

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String requisitionNo,
    required String requisitionDate,
    required String approvedBy,
  });
}
