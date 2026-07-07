import '../../domain/repositories/material_requisition_repository.dart';
import '../datasources/material_requisition_remote_ds.dart';

class MaterialRequisitionRepositoryImpl implements MaterialRequisitionRepository {
  final MaterialRequisitionRemoteDs _remote;

  MaterialRequisitionRepositoryImpl(this._remote);

  @override
  Future<List<Map<String, dynamic>>> listRequisitions({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) => _remote.listRequisitions(
        clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset,
      );

  @override
  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String requisitionNo,
    String? requisitionDate,
  }) => _remote.getHeader(clientId: clientId, companyId: companyId, requisitionNo: requisitionNo, requisitionDate: requisitionDate);

  @override
  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String requisitionNo,
    required String requisitionDate,
  }) => _remote.getLines(clientId: clientId, companyId: companyId, requisitionNo: requisitionNo, requisitionDate: requisitionDate);

  @override
  Future<List<Map<String, dynamic>>> getLocationsForIssue({
    required String clientId,
    required String companyId,
  }) => _remote.getLocationsForIssue(clientId: clientId, companyId: companyId);

  @override
  Future<List<Map<String, dynamic>>> getUsersForAutocomplete({
    required String clientId,
    required String companyId,
  }) => _remote.getUsersForAutocomplete(clientId: clientId, companyId: companyId);

  @override
  Future<List<Map<String, dynamic>>> getProductsForPicker({
    required String clientId,
    required String companyId,
    String? search,
  }) => _remote.getProductsForPicker(clientId: clientId, companyId: companyId, search: search);

  @override
  Future<Map<String, dynamic>?> getProductByBarcode({
    required String clientId,
    required String companyId,
    required String barcode,
  }) => _remote.getProductByBarcode(clientId: clientId, companyId: companyId, barcode: barcode);

  @override
  Future<List<Map<String, dynamic>>> getDepartments({
    required String clientId,
    required String companyId,
  }) => _remote.getDepartments(clientId: clientId, companyId: companyId);

  @override
  Future<List<Map<String, dynamic>>> getConsumptionAreasForDepartment({
    required String clientId,
    required String companyId,
    required String departmentId,
  }) => _remote.getConsumptionAreasForDepartment(clientId: clientId, companyId: companyId, departmentId: departmentId);

  @override
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required String userId,
  }) => _remote.save(header: header, lines: lines, userId: userId);

  @override
  Future<void> approve({
    required String clientId,
    required String companyId,
    required String requisitionNo,
    required String requisitionDate,
    required String approvedBy,
  }) => _remote.approve(
        clientId: clientId, companyId: companyId, requisitionNo: requisitionNo,
        requisitionDate: requisitionDate, approvedBy: approvedBy,
      );
}
