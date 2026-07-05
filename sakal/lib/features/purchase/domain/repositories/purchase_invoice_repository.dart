import '../../data/models/purchase_invoice_model.dart';

/// Always online — a Purchase Bill's whole point is checking against the
/// live "which GRNs are still unbilled" state, same reasoning GRN's own
/// Against-PO consolidation uses for staying online-only.
abstract class PurchaseInvoiceRepository {
  Future<List<PurchaseInvoiceModel>> listPurchaseInvoices({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  });

  Future<PurchaseInvoiceModel?> getHeader({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    String? invoiceDate,
  });

  Future<List<Map<String, dynamic>>> getPostedVoucherLines({
    required String clientId,
    required String companyId,
    required String voucherNo,
    required String voucherDate,
  });

  Future<List<Map<String, dynamic>>> getSuppliersWithPendingGrns({
    required String clientId,
    required String companyId,
  });

  Future<List<Map<String, dynamic>>> getPendingGrnsForSupplier({
    required String clientId,
    required String companyId,
    required String supplierId,
    String? excludeInvoiceNo,
  });

  Future<Map<String, double>> getGrnBillingDefaults({
    required String clientId,
    required String companyId,
    required List<Map<String, String>> grnRefs,
  });

  /// Returns the assigned invoice_no.
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, String>> grnRefs,
    required String userId,
  });

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
    required String approvedBy,
  });
}
