abstract class DepartmentConsumptionAreaRepository {
  Future<List<Map<String, dynamic>>> getDepartments({
    required String clientId,
    required String companyId,
  });

  Future<List<Map<String, dynamic>>> getConsumptionAreas({
    required String clientId,
    required String companyId,
  });

  Future<Set<String>> getAllLinkedAreaIds({
    required String clientId,
    required String companyId,
  });

  Future<List<Map<String, dynamic>>> getLinksForDepartment({
    required String clientId,
    required String companyId,
    required String departmentId,
  });

  Future<void> saveLink({required Map<String, dynamic> payload});

  Future<void> deleteLink({required String id, required String userId});
}
