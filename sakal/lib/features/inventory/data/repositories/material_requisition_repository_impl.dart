import 'dart:async';
import '../../domain/repositories/material_requisition_repository.dart';
import '../datasources/material_requisition_remote_ds.dart';
import '../datasources/material_requisition_local_ds.dart';

class MaterialRequisitionRepositoryImpl implements MaterialRequisitionRepository {
  final MaterialRequisitionRemoteDs _remote;
  final MaterialRequisitionLocalDs? _local; // null on Flutter Web (no Drift)
  final bool _isOffline;

  MaterialRequisitionRepositoryImpl(this._remote, this._local, this._isOffline);

  @override
  Future<List<Map<String, dynamic>>> listRequisitions({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) {
    if (_isOffline && _local != null) {
      return _local.listRequisitions(
        clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset,
      );
    }
    return _remote.listRequisitions(
      clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset,
    );
  }

  @override
  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String requisitionNo,
    String? requisitionDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getHeader(clientId: clientId, companyId: companyId, requisitionNo: requisitionNo, requisitionDate: requisitionDate);
    }
    final header = await _remote.getHeader(clientId: clientId, companyId: companyId, requisitionNo: requisitionNo, requisitionDate: requisitionDate);
    if (header != null && _local != null) unawaited(_local.cacheHeader(header));
    return header;
  }

  @override
  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String requisitionNo,
    required String requisitionDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getLines(clientId: clientId, companyId: companyId, requisitionNo: requisitionNo, requisitionDate: requisitionDate);
    }
    final lines = await _remote.getLines(clientId: clientId, companyId: companyId, requisitionNo: requisitionNo, requisitionDate: requisitionDate);
    if (_local != null) unawaited(_local.cacheLines(clientId, companyId, requisitionNo, requisitionDate, lines));
    return lines;
  }

  // Genuine offline gap (this module had zero master-data offline support
  // at all) — now served from the shared Master-Data Sync facility
  // (core/sync/master_data_modules.dart) when offline, matching the same
  // pattern already established for Sales Invoice/GRN/PO.
  @override
  Future<List<Map<String, dynamic>>> getLocationsForIssue({
    required String clientId,
    required String companyId,
  }) {
    if (_isOffline && _local != null) {
      return _local.getLocationsForIssue(clientId: clientId, companyId: companyId);
    }
    return _remote.getLocationsForIssue(clientId: clientId, companyId: companyId);
  }

  @override
  Future<List<Map<String, dynamic>>> getUsersForAutocomplete({
    required String clientId,
    required String companyId,
  }) {
    if (_isOffline && _local != null) {
      return _local.getUsersForAutocomplete(clientId: clientId, companyId: companyId);
    }
    return _remote.getUsersForAutocomplete(clientId: clientId, companyId: companyId);
  }

  @override
  Future<List<Map<String, dynamic>>> getProductsForPicker({
    required String clientId,
    required String companyId,
    String? search,
  }) {
    if (_isOffline && _local != null) {
      return _local.getProductsForPicker(clientId: clientId, companyId: companyId, search: search);
    }
    return _remote.getProductsForPicker(clientId: clientId, companyId: companyId, search: search);
  }

  @override
  Future<Map<String, dynamic>?> getProductByBarcode({
    required String clientId,
    required String companyId,
    required String barcode,
  }) {
    if (_isOffline && _local != null) {
      return _local.getProductByBarcode(barcode);
    }
    return _remote.getProductByBarcode(clientId: clientId, companyId: companyId, barcode: barcode);
  }

  @override
  Future<List<Map<String, dynamic>>> getDepartments({
    required String clientId,
    required String companyId,
  }) {
    if (_isOffline && _local != null) {
      return _local.getDepartments(clientId: clientId, companyId: companyId);
    }
    return _remote.getDepartments(clientId: clientId, companyId: companyId);
  }

  @override
  Future<List<Map<String, dynamic>>> getConsumptionAreasForDepartment({
    required String clientId,
    required String companyId,
    required String departmentId,
  }) {
    if (_isOffline && _local != null) {
      return _local.getConsumptionAreasForDepartment(clientId: clientId, companyId: companyId, departmentId: departmentId);
    }
    return _remote.getConsumptionAreasForDepartment(clientId: clientId, companyId: companyId, departmentId: departmentId);
  }

  @override
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required String userId,
  }) => _remote.save(header: header, lines: lines, userId: userId);

  @override
  Future<void> cacheRequisitionLocally({
    required String effectiveRequisitionNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
  }) => _local?.cacheFromMaps(effectiveRequisitionNo, header, lines) ?? Future.value();

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
