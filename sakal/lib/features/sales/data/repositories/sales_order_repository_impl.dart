import 'dart:async';
import '../../domain/repositories/sales_order_repository.dart';
import '../datasources/sales_order_remote_ds.dart';
import '../datasources/sales_order_local_ds.dart';

class SalesOrderRepositoryImpl implements SalesOrderRepository {
  final SalesOrderRemoteDs _remote;
  final SalesOrderLocalDs? _local; // null on Flutter Web (no Drift)
  final bool _isOffline;

  SalesOrderRepositoryImpl(this._remote, this._local, this._isOffline);

  @override
  Future<List<Map<String, dynamic>>> listOrders({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    String? orderMode,
    int     limit  = 50,
    int     offset = 0,
  }) {
    if (_isOffline && _local != null) {
      return _local.listOrders(
        clientId: clientId, companyId: companyId, search: search, status: status,
        orderMode: orderMode, limit: limit, offset: offset,
      );
    }
    return _remote.listOrders(
      clientId: clientId, companyId: companyId, search: search, status: status,
      orderMode: orderMode, limit: limit, offset: offset,
    );
  }

  @override
  Future<Map<String, dynamic>?> getHeader({
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
  Future<List<Map<String, dynamic>>> getLines({
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
  Future<List<Map<String, dynamic>>> getCharges({
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

  // ── Against-Quotation mode — online-only, no local fallback ──────────────

  @override
  Future<List<Map<String, dynamic>>> getConvertibleQuotations({
    required String clientId,
    required String companyId,
    String? search,
  }) => _remote.getConvertibleQuotations(clientId: clientId, companyId: companyId, search: search);

  @override
  Future<Map<String, dynamic>?> getQuotationHeader({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
  }) => _remote.getQuotationHeader(clientId: clientId, companyId: companyId, quotationNo: quotationNo, quotationDate: quotationDate);

  @override
  Future<List<Map<String, dynamic>>> getQuotationLines({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
  }) => _remote.getQuotationLines(clientId: clientId, companyId: companyId, quotationNo: quotationNo, quotationDate: quotationDate);

  @override
  Future<List<Map<String, dynamic>>> getQuotationCharges({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
  }) => _remote.getQuotationCharges(clientId: clientId, companyId: companyId, quotationNo: quotationNo, quotationDate: quotationDate);

  @override
  Future<void> convertProspectToCustomer({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
    required Map<String, dynamic> account,
    String? notes,
    required String userId,
  }) => _remote.convertProspectToCustomer(
        clientId: clientId, companyId: companyId, quotationNo: quotationNo, quotationDate: quotationDate,
        account: account, notes: notes, userId: userId,
      );

  // ── Direct mode: price/discount governance ───────────────────────────────

  @override
  Future<Map<String, dynamic>?> getActivePrice({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
    required String uomId,
    required String customerId,
    required String asOfDate,
    required String currencyCode,
  }) => _remote.getActivePrice(
        clientId: clientId, companyId: companyId, locationId: locationId,
        productId: productId, uomId: uomId, customerId: customerId, asOfDate: asOfDate,
        currencyCode: currencyCode,
      );

  @override
  Future<List<Map<String, dynamic>>> getPaymentTerms({
    required String clientId,
    required String companyId,
  }) => _remote.getPaymentTerms(clientId: clientId, companyId: companyId);

  @override
  Future<List<Map<String, dynamic>>> getIncoterms({
    required String clientId,
    required String companyId,
  }) => _remote.getIncoterms(clientId: clientId, companyId: companyId);

  @override
  Future<Map<String, dynamic>?> getUserSalesControls({
    required String clientId,
    required String companyId,
    required String userId,
  }) => _remote.getUserSalesControls(clientId: clientId, companyId: companyId, userId: userId);

  @override
  Future<Map<String, dynamic>?> getProductLocationCost({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) => _remote.getProductLocationCost(clientId: clientId, companyId: companyId, locationId: locationId, productId: productId);

  // ── Shared pickers ────────────────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>?> getCustomerDetails({required String customerId}) =>
      _remote.getCustomerDetails(customerId: customerId);

  @override
  Future<List<Map<String, dynamic>>> getUsersForAutocomplete({
    required String clientId,
    required String companyId,
  }) => _remote.getUsersForAutocomplete(clientId: clientId, companyId: companyId);

  @override
  Future<List<Map<String, dynamic>>> getProductsForPicker({
    required String clientId,
    required String companyId,
    String? search,
  }) => _remote.getProductsForPicker(clientId: clientId, companyId: companyId, search: search);

  @override
  Future<Map<String, dynamic>?> getProductByCode({
    required String clientId,
    required String companyId,
    required String code,
    required bool tryPartNumber,
  }) => _remote.getProductByCode(clientId: clientId, companyId: companyId, code: code, tryPartNumber: tryPartNumber);

  @override
  Future<List<Map<String, dynamic>>> getProductUoms(String productId) => _remote.getProductUoms(productId);

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
  Future<List<Map<String, dynamic>>> getAdditionalCharges({
    required String clientId,
    required String companyId,
  }) => _remote.getAdditionalCharges(clientId: clientId, companyId: companyId);

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
        clientId: clientId, companyId: companyId, orderNo: orderNo,
        orderDate: orderDate, approvedBy: approvedBy,
      );

  @override
  Future<void> cancel({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
    required String reason,
    required String userId,
  }) => _remote.cancel(
        clientId: clientId, companyId: companyId, orderNo: orderNo,
        orderDate: orderDate, reason: reason, userId: userId,
      );
}
