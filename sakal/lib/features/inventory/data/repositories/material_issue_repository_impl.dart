import '../../domain/repositories/material_issue_repository.dart';
import '../datasources/material_issue_remote_ds.dart';

class MaterialIssueRepositoryImpl implements MaterialIssueRepository {
  final MaterialIssueRemoteDs _remote;

  MaterialIssueRepositoryImpl(this._remote);

  @override
  Future<List<Map<String, dynamic>>> listIssues({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) => _remote.listIssues(clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset);

  @override
  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String issueNo,
    String? issueDate,
  }) => _remote.getHeader(clientId: clientId, companyId: companyId, issueNo: issueNo, issueDate: issueDate);

  @override
  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String issueNo,
  }) => _remote.getPostedVouchers(clientId: clientId, companyId: companyId, issueNo: issueNo);

  @override
  Future<List<Map<String, dynamic>>> getPostedVoucherLines({
    required String clientId,
    required String companyId,
    required String voucherNo,
    required String voucherDate,
  }) => _remote.getPostedVoucherLines(clientId: clientId, companyId: companyId, voucherNo: voucherNo, voucherDate: voucherDate);

  @override
  Future<List<Map<String, dynamic>>> getFulfillableRequisitions({
    required String clientId,
    required String companyId,
    required String locationId,
  }) => _remote.getFulfillableRequisitions(clientId: clientId, companyId: companyId, locationId: locationId);

  @override
  Future<List<Map<String, dynamic>>> getRequisitionLines({
    required String clientId,
    required String companyId,
    required String requisitionNo,
    required String requisitionDate,
  }) => _remote.getRequisitionLines(clientId: clientId, companyId: companyId, requisitionNo: requisitionNo, requisitionDate: requisitionDate);

  @override
  Future<num> getBatchBalance({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
    required String batchNo,
  }) => _remote.getBatchBalance(clientId: clientId, companyId: companyId, locationId: locationId, productId: productId, batchNo: batchNo);

  @override
  Future<List<Map<String, dynamic>>> getAvailableBatches({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) => _remote.getAvailableBatches(clientId: clientId, companyId: companyId, locationId: locationId, productId: productId);

  @override
  Future<List<Map<String, dynamic>>> getAvailableSerials({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) => _remote.getAvailableSerials(clientId: clientId, companyId: companyId, locationId: locationId, productId: productId);

  @override
  Future<List<Map<String, dynamic>>> getIssueLineBatches({
    required String clientId,
    required String companyId,
    required String issueNo,
    required String issueDate,
    required int    lineSerial,
  }) => _remote.getIssueLineBatches(clientId: clientId, companyId: companyId, issueNo: issueNo, issueDate: issueDate, lineSerial: lineSerial);

  @override
  Future<List<Map<String, dynamic>>> getIssueLineSerials({
    required String clientId,
    required String companyId,
    required String issueNo,
    required String issueDate,
    required int    lineSerial,
  }) => _remote.getIssueLineSerials(clientId: clientId, companyId: companyId, issueNo: issueNo, issueDate: issueDate, lineSerial: lineSerial);

  @override
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required String userId,
  }) => _remote.save(header: header, lines: lines, batches: batches, serials: serials, userId: userId);

  @override
  Future<void> approve({
    required String clientId,
    required String companyId,
    required String issueNo,
    required String issueDate,
    required String approvedBy,
  }) => _remote.approve(clientId: clientId, companyId: companyId, issueNo: issueNo, issueDate: issueDate, approvedBy: approvedBy);
}
