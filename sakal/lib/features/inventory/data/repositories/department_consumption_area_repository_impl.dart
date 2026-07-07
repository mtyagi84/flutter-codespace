import '../../domain/repositories/department_consumption_area_repository.dart';
import '../datasources/department_consumption_area_remote_ds.dart';

class DepartmentConsumptionAreaRepositoryImpl implements DepartmentConsumptionAreaRepository {
  final DepartmentConsumptionAreaRemoteDs _remote;

  DepartmentConsumptionAreaRepositoryImpl(this._remote);

  @override
  Future<List<Map<String, dynamic>>> getDepartments({
    required String clientId,
    required String companyId,
  }) => _remote.getDepartments(clientId: clientId, companyId: companyId);

  @override
  Future<List<Map<String, dynamic>>> getConsumptionAreas({
    required String clientId,
    required String companyId,
  }) => _remote.getConsumptionAreas(clientId: clientId, companyId: companyId);

  @override
  Future<Set<String>> getAllLinkedAreaIds({
    required String clientId,
    required String companyId,
  }) => _remote.getAllLinkedAreaIds(clientId: clientId, companyId: companyId);

  @override
  Future<List<Map<String, dynamic>>> getLinksForDepartment({
    required String clientId,
    required String companyId,
    required String departmentId,
  }) => _remote.getLinksForDepartment(clientId: clientId, companyId: companyId, departmentId: departmentId);

  @override
  Future<void> saveLink({required Map<String, dynamic> payload}) => _remote.saveLink(payload: payload);

  @override
  Future<void> deleteLink({required String id, required String userId}) => _remote.deleteLink(id: id, userId: userId);
}
