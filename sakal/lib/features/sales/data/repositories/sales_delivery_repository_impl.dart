import '../../domain/repositories/sales_delivery_repository.dart';
import '../datasources/sales_delivery_remote_ds.dart';
import '../datasources/sales_delivery_local_ds.dart';

class SalesDeliveryRepositoryImpl implements SalesDeliveryRepository {
  final SalesDeliveryRemoteDs _remote;
  final SalesDeliveryLocalDs? _local; // null on Flutter Web (no Drift)
  final bool _isOffline;

  SalesDeliveryRepositoryImpl(this._remote, this._local, this._isOffline);

  @override
  Future<List<Map<String, dynamic>>> listDeliveries({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) {
    if (_isOffline && _local != null) {
      return _local.listDeliveries(clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset);
    }
    return _remote.listDeliveries(clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset);
  }

  @override
  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String deliveryNo,
    String? deliveryDate,
  }) {
    if (_isOffline && _local != null) {
      return _local.getHeader(clientId: clientId, companyId: companyId, deliveryNo: deliveryNo, deliveryDate: deliveryDate);
    }
    return _remote.getHeader(clientId: clientId, companyId: companyId, deliveryNo: deliveryNo, deliveryDate: deliveryDate);
  }

  @override
  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String deliveryNo,
    required String deliveryDate,
  }) {
    if (_isOffline && _local != null) {
      return _local.getLines(clientId: clientId, companyId: companyId, deliveryNo: deliveryNo, deliveryDate: deliveryDate);
    }
    return _remote.getLines(clientId: clientId, companyId: companyId, deliveryNo: deliveryNo, deliveryDate: deliveryDate);
  }

  // Everything below is online-only — the picker/candidate/review reads
  // are meaningless against a stale offline replica (live stock, live
  // pending-qty rollup), same reasoning Sales Invoice's own Manager
  // Review reads already established.
  @override
  Future<List<Map<String, dynamic>>> getPendingDeliveryInvoices({
    required String clientId,
    required String companyId,
    String? search,
  }) => _remote.getPendingDeliveryInvoices(clientId: clientId, companyId: companyId, search: search);

  @override
  Future<Map<String, dynamic>?> getDeliveryStatusForInvoice({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  }) => _remote.getDeliveryStatusForInvoice(clientId: clientId, companyId: companyId, invoiceNo: invoiceNo, invoiceDate: invoiceDate);

  @override
  Future<List<Map<String, dynamic>>> getDeliveryStatusForInvoices({
    required String clientId,
    required String companyId,
    required List<String> invoiceNos,
  }) => _remote.getDeliveryStatusForInvoices(clientId: clientId, companyId: companyId, invoiceNos: invoiceNos);

  @override
  Future<List<Map<String, dynamic>>> getInvoiceLines({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  }) => _remote.getInvoiceLines(clientId: clientId, companyId: companyId, invoiceNo: invoiceNo, invoiceDate: invoiceDate);

  @override
  Future<List<Map<String, dynamic>>> getBatchStockBalance({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) => _remote.getBatchStockBalance(clientId: clientId, companyId: companyId, locationId: locationId, productId: productId);

  @override
  Future<List<Map<String, dynamic>>> getSerialStockStatus({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) => _remote.getSerialStockStatus(clientId: clientId, companyId: companyId, locationId: locationId, productId: productId);

  @override
  Future<List<Map<String, dynamic>>> getDeliveryLineBatches({
    required String clientId,
    required String companyId,
    required String deliveryNo,
    required String deliveryDate,
  }) => _remote.getDeliveryLineBatches(clientId: clientId, companyId: companyId, deliveryNo: deliveryNo, deliveryDate: deliveryDate);

  @override
  Future<List<Map<String, dynamic>>> getDeliveryLineSerials({
    required String clientId,
    required String companyId,
    required String deliveryNo,
    required String deliveryDate,
  }) => _remote.getDeliveryLineSerials(clientId: clientId, companyId: companyId, deliveryNo: deliveryNo, deliveryDate: deliveryDate);

  @override
  Future<List<Map<String, dynamic>>> getCustomerDeliveryLocations({
    required String clientId,
    required String companyId,
    required String customerId,
  }) => _remote.getCustomerDeliveryLocations(clientId: clientId, companyId: companyId, customerId: customerId);

  @override
  Future<String> saveCustomerDeliveryLocation({
    required Map<String, dynamic> payload,
    required bool isNew,
    required String userId,
  }) => _remote.saveCustomerDeliveryLocation(payload: payload, isNew: isNew, userId: userId);

  @override
  Future<void> deleteCustomerDeliveryLocation({required String id, required String userId}) =>
      _remote.deleteCustomerDeliveryLocation(id: id, userId: userId);

  @override
  Future<Map<String, dynamic>?> getTransportDetails({
    required String clientId,
    required String companyId,
    required String deliveryNo,
    required String deliveryDate,
  }) => _remote.getTransportDetails(clientId: clientId, companyId: companyId, deliveryNo: deliveryNo, deliveryDate: deliveryDate);

  @override
  Future<List<Map<String, dynamic>>> getUsersForAutocomplete({
    required String clientId,
    required String companyId,
  }) => _remote.getUsersForAutocomplete(clientId: clientId, companyId: companyId);

  @override
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    Map<String, dynamic>? transport,
    required String userId,
  }) => _remote.save(header: header, lines: lines, batches: batches, serials: serials, transport: transport, userId: userId);

  @override
  Future<void> approve({
    required String clientId,
    required String companyId,
    required String deliveryNo,
    required String deliveryDate,
    required String approvedBy,
  }) => _remote.approve(clientId: clientId, companyId: companyId, deliveryNo: deliveryNo, deliveryDate: deliveryDate, approvedBy: approvedBy);

  @override
  Future<List<Map<String, dynamic>>> listDraftDeliveriesForReview({
    required String clientId,
    required String companyId,
    required String locationId,
  }) => _remote.listDraftDeliveriesForReview(clientId: clientId, companyId: companyId, locationId: locationId);

  @override
  Future<Map<String, dynamic>?> getStockPreview({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) => _remote.getStockPreview(clientId: clientId, companyId: companyId, locationId: locationId, productId: productId);

  @override
  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String deliveryNo,
  }) => _remote.getPostedVouchers(clientId: clientId, companyId: companyId, deliveryNo: deliveryNo);

  @override
  Future<List<Map<String, dynamic>>> getPostedVoucherLines({
    required String clientId,
    required String companyId,
    required String voucherNo,
    required String voucherDate,
  }) => _remote.getPostedVoucherLines(clientId: clientId, companyId: companyId, voucherNo: voucherNo, voucherDate: voucherDate);

  @override
  Future<void> cacheDeliveryLocally({
    required String effectiveDeliveryNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
  }) => _local?.cacheFromMaps(effectiveDeliveryNo, header, lines) ?? Future.value();
}
