import 'dart:async';
import '../../domain/repositories/purchase_order_repository.dart';
import '../datasources/purchase_order_remote_ds.dart';
import '../datasources/purchase_order_local_ds.dart';
import '../models/po_charge_line_model.dart';
import '../models/purchase_order_line_model.dart';
import '../models/purchase_order_model.dart';

class PurchaseOrderRepositoryImpl implements PurchaseOrderRepository {
  final PurchaseOrderRemoteDs  _remote;
  final PurchaseOrderLocalDs?  _local;   // null on Flutter Web (no Drift)
  final bool                   _isOffline;

  PurchaseOrderRepositoryImpl(this._remote, this._local, this._isOffline);

  @override
  Future<List<PurchaseOrderModel>> listOrders({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) {
    if (_isOffline && _local != null) {
      return _local.listOrders(
        clientId: clientId, companyId: companyId,
        search: search, status: status, limit: limit, offset: offset,
      );
    }
    // Online: remote is the source of truth for browsing history. Offline-created
    // (not-yet-synced) orders are already cached via cacheOrderLocally and don't
    // need caching again here — transaction history browsing isn't guaranteed
    // offline, only newly-created docs are (same rationale as Finance Voucher).
    return _remote.listOrders(
      clientId: clientId, companyId: companyId,
      search: search, status: status, limit: limit, offset: offset,
    );
  }

  @override
  Future<PurchaseOrderModel?> getHeader({
    required String clientId,
    required String companyId,
    required String orderNo,
    String? orderDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getHeader(clientId: clientId, companyId: companyId, orderNo: orderNo, orderDate: orderDate);
    }
    final header = await _remote.getHeader(clientId: clientId, companyId: companyId, orderNo: orderNo, orderDate: orderDate);
    if (header != null && _local != null) unawaited(_local.cacheHeader(header));
    return header;
  }

  @override
  Future<List<PurchaseOrderLineModel>> getLines({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getLines(clientId: clientId, companyId: companyId, orderNo: orderNo, orderDate: orderDate);
    }
    final lines = await _remote.getLines(clientId: clientId, companyId: companyId, orderNo: orderNo, orderDate: orderDate);
    if (_local != null) unawaited(_local.cacheLines(clientId, companyId, orderNo, orderDate, lines));
    return lines;
  }

  @override
  Future<List<PoChargeLineModel>> getCharges({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getCharges(clientId: clientId, companyId: companyId, orderNo: orderNo, orderDate: orderDate);
    }
    final charges = await _remote.getCharges(clientId: clientId, companyId: companyId, orderNo: orderNo, orderDate: orderDate);
    if (_local != null) unawaited(_local.cacheCharges(clientId, companyId, orderNo, orderDate, charges));
    return charges;
  }

  @override
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> charges,
    required String userId,
  }) => _remote.save(header: header, lines: lines, charges: charges, userId: userId);

  @override
  Future<void> cacheOrderLocally({
    required String effectiveOrderNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> charges,
  }) => _local?.cacheFromMaps(effectiveOrderNo, header, lines, charges) ?? Future.value();

  @override
  Future<void> approve({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
    required String approvedBy,
  }) => _remote.approve(
        clientId: clientId, companyId: companyId,
        orderNo: orderNo, orderDate: orderDate, approvedBy: approvedBy,
      );

  @override
  Future<List<Map<String, dynamic>>> getAdditionalCharges({
    required String clientId,
    required String companyId,
  }) => _remote.getAdditionalCharges(clientId: clientId, companyId: companyId);

  @override
  Future<List<Map<String, dynamic>>> getProductsForPicker({
    required String clientId,
    required String companyId,
    String? search,
  }) => _remote.getProductsForPicker(clientId: clientId, companyId: companyId, search: search);

  @override
  Future<List<Map<String, dynamic>>> getCommonMastersByType({
    required String clientId,
    required String companyId,
    required String typeKey,
  }) => _remote.getCommonMastersByType(clientId: clientId, companyId: companyId, typeKey: typeKey);

  @override
  Future<List<Map<String, dynamic>>> getTaxGroups({
    required String clientId,
    required String companyId,
  }) => _remote.getTaxGroups(clientId: clientId, companyId: companyId);

  @override
  Future<Map<String, List<String>>> getTaxGroupMemberTaxIds(List<String> groupIds) =>
      _remote.getTaxGroupMemberTaxIds(groupIds);

  @override
  Future<Map<String, double>> getTaxRatesByIds({
    required List<String> taxIds,
    required String asOfDate,
  }) => _remote.getTaxRatesByIds(taxIds: taxIds, asOfDate: asOfDate);

  @override
  Future<Map<String, double>> getProductStockSnapshot({
    required String productId,
    required String locationId,
  }) => _remote.getProductStockSnapshot(productId: productId, locationId: locationId);

  @override
  Future<List<Map<String, dynamic>>> getUsers({
    required String clientId,
    required String companyId,
  }) => _remote.getUsers(clientId: clientId, companyId: companyId);

  @override
  Future<double?> getExchangeRate({
    required String companyId,
    required String locationId,
    required String fromCurrency,
    required String toCurrency,
    required String rateDate,
  }) => _remote.getExchangeRate(
        companyId: companyId, locationId: locationId,
        fromCurrency: fromCurrency, toCurrency: toCurrency, rateDate: rateDate,
      );
}
