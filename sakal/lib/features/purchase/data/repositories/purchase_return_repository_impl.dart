import '../../domain/repositories/purchase_return_repository.dart';
import '../datasources/purchase_return_remote_ds.dart';
import '../models/purchase_return_model.dart';

class PurchaseReturnRepositoryImpl implements PurchaseReturnRepository {
  final PurchaseReturnRemoteDs _remote;

  PurchaseReturnRepositoryImpl(this._remote);

  @override
  Future<List<PurchaseReturnModel>> listPurchaseReturns({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) => _remote.listPurchaseReturns(
        clientId: clientId, companyId: companyId, search: search, status: status,
        limit: limit, offset: offset,
      );

  @override
  Future<PurchaseReturnModel?> getHeader({
    required String clientId,
    required String companyId,
    required String returnNo,
    String? returnDate,
  }) => _remote.getHeader(clientId: clientId, companyId: companyId, returnNo: returnNo, returnDate: returnDate);

  @override
  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String returnNo,
  }) => _remote.getPostedVouchers(clientId: clientId, companyId: companyId, returnNo: returnNo);

  @override
  Future<List<Map<String, dynamic>>> getPostedVoucherLines({
    required String clientId,
    required String companyId,
    required String voucherNo,
    required String voucherDate,
  }) => _remote.getPostedVoucherLines(
        clientId: clientId, companyId: companyId, voucherNo: voucherNo, voucherDate: voucherDate,
      );

  @override
  Future<List<Map<String, dynamic>>> getSuppliersWithApprovedGrns({
    required String clientId,
    required String companyId,
  }) => _remote.getSuppliersWithApprovedGrns(clientId: clientId, companyId: companyId);

  @override
  Future<List<Map<String, dynamic>>> getGrnsForSupplier({
    required String clientId,
    required String companyId,
    required String supplierId,
  }) => _remote.getGrnsForSupplier(clientId: clientId, companyId: companyId, supplierId: supplierId);

  @override
  Future<List<Map<String, dynamic>>> getGrnLines({
    required String clientId,
    required String companyId,
    required String grnNo,
    required String grnDate,
  }) => _remote.getGrnLines(clientId: clientId, companyId: companyId, grnNo: grnNo, grnDate: grnDate);

  @override
  Future<List<Map<String, dynamic>>> getGrnCharges({
    required String clientId,
    required String companyId,
    required String grnNo,
    required String grnDate,
  }) => _remote.getGrnCharges(clientId: clientId, companyId: companyId, grnNo: grnNo, grnDate: grnDate);

  @override
  Future<List<Map<String, dynamic>>> getGrnLineBatches({
    required String clientId,
    required String companyId,
    required String grnNo,
    required String grnDate,
    required int    lineSerial,
  }) => _remote.getGrnLineBatches(
        clientId: clientId, companyId: companyId, grnNo: grnNo, grnDate: grnDate, lineSerial: lineSerial,
      );

  @override
  Future<List<Map<String, dynamic>>> getGrnLineSerials({
    required String clientId,
    required String companyId,
    required String grnNo,
    required String grnDate,
    required int    lineSerial,
  }) => _remote.getGrnLineSerials(
        clientId: clientId, companyId: companyId, grnNo: grnNo, grnDate: grnDate, lineSerial: lineSerial,
      );

  @override
  Future<num> getBatchBalance({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
    required String batchNo,
  }) => _remote.getBatchBalance(
        clientId: clientId, companyId: companyId, locationId: locationId, productId: productId, batchNo: batchNo,
      );

  @override
  Future<String> getSerialStatus({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
    required String serialNo,
  }) => _remote.getSerialStatus(
        clientId: clientId, companyId: companyId, locationId: locationId, productId: productId, serialNo: serialNo,
      );

  @override
  Future<List<Map<String, dynamic>>> getReturnLines({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
  }) => _remote.getReturnLines(clientId: clientId, companyId: companyId, returnNo: returnNo, returnDate: returnDate);

  @override
  Future<List<Map<String, dynamic>>> getReturnCharges({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
  }) => _remote.getReturnCharges(clientId: clientId, companyId: companyId, returnNo: returnNo, returnDate: returnDate);

  @override
  Future<List<Map<String, dynamic>>> getReturnLineBatches({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
    required int    lineSerial,
  }) => _remote.getReturnLineBatches(
        clientId: clientId, companyId: companyId, returnNo: returnNo, returnDate: returnDate, lineSerial: lineSerial,
      );

  @override
  Future<List<Map<String, dynamic>>> getReturnLineSerials({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
    required int    lineSerial,
  }) => _remote.getReturnLineSerials(
        clientId: clientId, companyId: companyId, returnNo: returnNo, returnDate: returnDate, lineSerial: lineSerial,
      );

  @override
  Future<List<Map<String, dynamic>>> getCommonMastersByType({
    required String clientId,
    required String companyId,
    required String typeKey,
  }) => _remote.getCommonMastersByType(clientId: clientId, companyId: companyId, typeKey: typeKey);

  @override
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required List<Map<String, dynamic>> charges,
    required String userId,
  }) => _remote.save(header: header, lines: lines, batches: batches, serials: serials, charges: charges, userId: userId);

  @override
  Future<void> approve({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
    required bool   reopenPo,
    required String approvedBy,
  }) => _remote.approve(
        clientId: clientId, companyId: companyId, returnNo: returnNo, returnDate: returnDate,
        reopenPo: reopenPo, approvedBy: approvedBy,
      );
}
