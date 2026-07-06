import '../../data/models/purchase_return_model.dart';

/// Always online — same reasoning as Purchase Bill/GRN's own Against-PO
/// consolidation: this screen checks live GRN/billed-status state.
abstract class PurchaseReturnRepository {
  Future<List<PurchaseReturnModel>> listPurchaseReturns({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  });

  Future<PurchaseReturnModel?> getHeader({
    required String clientId,
    required String companyId,
    required String returnNo,
    String? returnDate,
  });

  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String returnNo,
  });

  Future<List<Map<String, dynamic>>> getPostedVoucherLines({
    required String clientId,
    required String companyId,
    required String voucherNo,
    required String voucherDate,
  });

  Future<List<Map<String, dynamic>>> getSuppliersWithApprovedGrns({
    required String clientId,
    required String companyId,
  });

  Future<List<Map<String, dynamic>>> getGrnsForSupplier({
    required String clientId,
    required String companyId,
    required String supplierId,
  });

  Future<List<Map<String, dynamic>>> getGrnLines({
    required String clientId,
    required String companyId,
    required String grnNo,
    required String grnDate,
  });

  Future<List<Map<String, dynamic>>> getGrnCharges({
    required String clientId,
    required String companyId,
    required String grnNo,
    required String grnDate,
  });

  /// Returns the assigned return_no.
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> charges,
    required String userId,
  });

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
    required bool   reopenPo,
    required String approvedBy,
  });
}
