import '../../data/models/purchase_return_model.dart';

/// listPurchaseReturns/getHeader/getReturnLines/getReturnCharges read from the
/// local cache when offline (and `save` can enqueue for later sync); every
/// other method — GRN/supplier picker, batch/serial candidates — stays
/// online-only, since those check live GRN/billed-status state the same way
/// Purchase Bill/GRN's own Against-PO consolidation does. In practice this
/// means an already-loaded return can be edited and saved offline, but a
/// brand-new return can't be meaningfully started fully offline (no cached
/// supplier/GRN candidates to pick from).
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

  Future<Set<String>> getFullyReturnedGrnKeys({
    required String clientId,
    required String companyId,
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

  Future<List<Map<String, dynamic>>> getGrnLineBatches({
    required String clientId,
    required String companyId,
    required String grnNo,
    required String grnDate,
    required int    lineSerial,
  });

  Future<List<Map<String, dynamic>>> getGrnLineSerials({
    required String clientId,
    required String companyId,
    required String grnNo,
    required String grnDate,
    required int    lineSerial,
  });

  Future<num> getBatchBalance({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
    required String batchNo,
  });

  Future<String> getSerialStatus({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
    required String serialNo,
  });

  Future<List<Map<String, dynamic>>> getReturnLines({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
  });

  Future<List<Map<String, dynamic>>> getReturnCharges({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
  });

  Future<List<Map<String, dynamic>>> getReturnLineBatches({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
    required int    lineSerial,
  });

  Future<List<Map<String, dynamic>>> getReturnLineSerials({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
    required int    lineSerial,
  });

  Future<List<Map<String, dynamic>>> getCommonMastersByType({
    required String clientId,
    required String companyId,
    required String typeKey,
  });

  /// Returns the assigned return_no.
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required List<Map<String, dynamic>> charges,
    required String userId,
  });

  /// Caches a return locally for offline read-back. Called after every
  /// online save and on every offline save (before enqueue).
  Future<void> cacheReturnLocally({
    required String effectiveReturnNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required List<Map<String, dynamic>> charges,
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
