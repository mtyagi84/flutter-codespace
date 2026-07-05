import '../../domain/repositories/purchase_invoice_repository.dart';
import '../datasources/purchase_invoice_remote_ds.dart';
import '../models/purchase_invoice_model.dart';

class PurchaseInvoiceRepositoryImpl implements PurchaseInvoiceRepository {
  final PurchaseInvoiceRemoteDs _remote;

  PurchaseInvoiceRepositoryImpl(this._remote);

  @override
  Future<List<PurchaseInvoiceModel>> listPurchaseInvoices({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) => _remote.listPurchaseInvoices(
        clientId: clientId, companyId: companyId, search: search, status: status,
        limit: limit, offset: offset,
      );

  @override
  Future<PurchaseInvoiceModel?> getHeader({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    String? invoiceDate,
  }) => _remote.getHeader(clientId: clientId, companyId: companyId, invoiceNo: invoiceNo, invoiceDate: invoiceDate);

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
  Future<List<Map<String, dynamic>>> getSuppliersWithPendingGrns({
    required String clientId,
    required String companyId,
  }) => _remote.getSuppliersWithPendingGrns(clientId: clientId, companyId: companyId);

  @override
  Future<List<Map<String, dynamic>>> getPendingGrnsForSupplier({
    required String clientId,
    required String companyId,
    required String supplierId,
    String? excludeInvoiceNo,
  }) => _remote.getPendingGrnsForSupplier(
        clientId: clientId, companyId: companyId, supplierId: supplierId, excludeInvoiceNo: excludeInvoiceNo,
      );

  @override
  Future<Map<String, double>> getGrnBillingDefaults({
    required String clientId,
    required String companyId,
    required List<Map<String, String>> grnRefs,
  }) => _remote.getGrnBillingDefaults(clientId: clientId, companyId: companyId, grnRefs: grnRefs);

  @override
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, String>> grnRefs,
    required String userId,
  }) => _remote.save(header: header, grnRefs: grnRefs, userId: userId);

  @override
  Future<void> approve({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
    required String approvedBy,
  }) => _remote.approve(
        clientId: clientId, companyId: companyId, invoiceNo: invoiceNo, invoiceDate: invoiceDate, approvedBy: approvedBy,
      );
}
