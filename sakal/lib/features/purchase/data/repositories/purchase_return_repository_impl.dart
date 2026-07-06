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
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> charges,
    required String userId,
  }) => _remote.save(header: header, lines: lines, charges: charges, userId: userId);

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
