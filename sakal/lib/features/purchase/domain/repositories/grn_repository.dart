import '../../data/models/grn_charge_line_model.dart';
import '../../data/models/grn_line_model.dart';
import '../../data/models/grn_model.dart';

abstract class GrnRepository {
  Future<List<GrnModel>> listGrns({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  });

  Future<GrnModel?> getHeader({
    required String clientId,
    required String companyId,
    required String grnNo,
    String? grnDate,
  });

  Future<List<GrnLineModel>> getLines({
    required String clientId,
    required String companyId,
    required String grnNo,
    required String grnDate,
  });

  Future<List<GrnChargeLineModel>> getCharges({
    required String clientId,
    required String companyId,
    required String grnNo,
    required String grnDate,
  });

  /// GL lines fn_post_voucher created when this GRN was approved.
  Future<List<Map<String, dynamic>>> getPostedVoucherLines({
    required String clientId,
    required String companyId,
    required String voucherNo,
    required String voucherDate,
  });

  /// Returns the assigned grn_no. Always online — never called while offline.
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required List<Map<String, dynamic>> charges,
    required String userId,
  });

  // Cache a GRN locally for offline read-back. Called after every online save
  // and on every offline save (before enqueue).
  Future<void> cacheGrnLocally({
    required String effectiveGrnNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required List<Map<String, dynamic>> charges,
  });

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String grnNo,
    required String grnDate,
    required String approvedBy,
  });

  // ── Against-PO consolidation — always online (needs live PO balances) ──────

  Future<List<Map<String, dynamic>>> getSuppliersWithOpenPos({
    required String clientId,
    required String companyId,
  });

  Future<List<Map<String, dynamic>>> getOpenPurchaseOrdersForSupplier({
    required String clientId,
    required String companyId,
    required String supplierId,
  });

  Future<List<Map<String, dynamic>>> getPendingPoLines({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
    String? excludeGrnNo,
  });

  Future<List<Map<String, dynamic>>> getPoChargeLinesForOrder({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  });

  // ── Reference data ──────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getAdditionalCharges({
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

  Future<List<Map<String, dynamic>>> getCommonMastersByType({
    required String clientId,
    required String companyId,
    required String typeKey,
  });

  Future<List<Map<String, dynamic>>> getTaxGroups({
    required String clientId,
    required String companyId,
  });

  Future<Map<String, List<String>>> getTaxGroupMemberTaxIds(List<String> groupIds);

  Future<Map<String, double>> getTaxRatesByIds({
    required List<String> taxIds,
    required String asOfDate,
  });

  Future<double?> getExchangeRate({
    required String companyId,
    required String locationId,
    required String fromCurrency,
    required String toCurrency,
    required String rateDate,
  });

  /// Product's moving-average cost at this location, in base currency —
  /// baseline for the GRN rate cost-variance warning. Null if no prior
  /// stock/cost exists yet for this product+location.
  Future<double?> getProductLastCostPrice({
    required String productId,
    required String locationId,
  });
}
