import '../../data/models/po_charge_line_model.dart';
import '../../data/models/purchase_order_line_model.dart';
import '../../data/models/purchase_order_model.dart';

abstract class PurchaseOrderRepository {
  Future<List<PurchaseOrderModel>> listOrders({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  });

  Future<PurchaseOrderModel?> getHeader({
    required String clientId,
    required String companyId,
    required String orderNo,
    String? orderDate,
  });

  Future<List<PurchaseOrderLineModel>> getLines({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  });

  Future<List<PoChargeLineModel>> getCharges({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  });

  /// Returns the assigned order_no. Always online — never called while offline.
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> charges,
    required String userId,
  });

  // Cache a PO locally for offline read-back.
  // Called after every online save and on every offline save (before enqueue).
  Future<void> cacheOrderLocally({
    required String effectiveOrderNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> charges,
  });

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
    required String approvedBy,
  });

  // ── Reference data — remote-only for now; becomes offline-safe once the
  // masters they read from (Accounts/TaxGroups/AdditionalCharges/Products)
  // get their own Drift caches. ──────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getAdditionalCharges({
    required String clientId,
    required String companyId,
  });

  Future<List<Map<String, dynamic>>> getProductsForPicker({
    required String clientId,
    required String companyId,
    String? search,
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

  Future<Map<String, double>> getProductStockSnapshot({
    required String productId,
    required String locationId,
  });

  Future<List<Map<String, dynamic>>> getUsers({
    required String clientId,
    required String companyId,
  });

  Future<double?> getExchangeRate({
    required String companyId,
    required String locationId,
    required String fromCurrency,
    required String toCurrency,
    required String rateDate,
  });
}
