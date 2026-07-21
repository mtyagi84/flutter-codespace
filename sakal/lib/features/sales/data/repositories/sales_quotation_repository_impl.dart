import 'dart:async';
import '../../domain/repositories/sales_quotation_repository.dart';
import '../datasources/sales_quotation_remote_ds.dart';
import '../datasources/sales_quotation_local_ds.dart';

class SalesQuotationRepositoryImpl implements SalesQuotationRepository {
  final SalesQuotationRemoteDs _remote;
  final SalesQuotationLocalDs? _local; // null on Flutter Web (no Drift)
  final bool _isOffline;

  SalesQuotationRepositoryImpl(this._remote, this._local, this._isOffline);

  @override
  Future<List<Map<String, dynamic>>> listQuotations({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) {
    if (_isOffline && _local != null) {
      return _local.listQuotations(
        clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset,
      );
    }
    return _remote.listQuotations(
      clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset,
    );
  }

  @override
  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String quotationNo,
    String? quotationDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getHeader(clientId: clientId, companyId: companyId, quotationNo: quotationNo, quotationDate: quotationDate);
    }
    final header = await _remote.getHeader(clientId: clientId, companyId: companyId, quotationNo: quotationNo, quotationDate: quotationDate);
    if (header != null && _local != null) unawaited(_local.cacheHeader(header));
    return header;
  }

  @override
  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getLines(clientId: clientId, companyId: companyId, quotationNo: quotationNo, quotationDate: quotationDate);
    }
    final lines = await _remote.getLines(clientId: clientId, companyId: companyId, quotationNo: quotationNo, quotationDate: quotationDate);
    if (_local != null) unawaited(_local.cacheLines(clientId, companyId, quotationNo, quotationDate, lines));
    return lines;
  }

  @override
  Future<List<Map<String, dynamic>>> getCharges({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getCharges(clientId: clientId, companyId: companyId, quotationNo: quotationNo, quotationDate: quotationDate);
    }
    final charges = await _remote.getCharges(clientId: clientId, companyId: companyId, quotationNo: quotationNo, quotationDate: quotationDate);
    if (_local != null) unawaited(_local.cacheCharges(clientId, companyId, quotationNo, quotationDate, charges));
    return charges;
  }

  @override
  Future<Map<String, dynamic>?> getCustomerDetails({required String customerId}) =>
      _remote.getCustomerDetails(customerId: customerId);

  @override
  Future<List<Map<String, dynamic>>> getUsersForAutocomplete({
    required String clientId,
    required String companyId,
  }) => _remote.getUsersForAutocomplete(clientId: clientId, companyId: companyId);

  @override
  Future<List<Map<String, dynamic>>> getSalesExecutivesForPicker({
    required String clientId,
    required String companyId,
  }) => _remote.getSalesExecutivesForPicker(clientId: clientId, companyId: companyId);

  @override
  Future<List<Map<String, dynamic>>> getProductsForPicker({
    required String clientId,
    required String companyId,
    String? search,
  }) => _remote.getProductsForPicker(clientId: clientId, companyId: companyId, search: search);

  @override
  Future<Map<String, dynamic>?> getProductByBarcode({
    required String clientId,
    required String companyId,
    required String barcode,
  }) => _remote.getProductByBarcode(clientId: clientId, companyId: companyId, barcode: barcode);

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
  Future<Map<String, dynamic>?> getActivePrice({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
    required String uomId,
    required String? customerId,
    required String asOfDate,
    required String currencyCode,
  }) => _remote.getActivePrice(
        clientId: clientId, companyId: companyId, locationId: locationId,
        productId: productId, uomId: uomId, customerId: customerId,
        asOfDate: asOfDate, currencyCode: currencyCode,
      );

  @override
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> charges,
    required String userId,
  }) => _remote.save(header: header, lines: lines, charges: charges, userId: userId);

  @override
  Future<void> cacheQuotationLocally({
    required String effectiveQuotationNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> charges,
  }) => _local?.cacheFromMaps(effectiveQuotationNo, header, lines, charges) ?? Future.value();

  @override
  Future<void> approve({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
    required String approvedBy,
  }) => _remote.approve(
        clientId: clientId, companyId: companyId, quotationNo: quotationNo,
        quotationDate: quotationDate, approvedBy: approvedBy,
      );

  @override
  Future<void> updateStatus({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
    required String newStatus,
    required String userId,
  }) => _remote.updateStatus(
        clientId: clientId, companyId: companyId, quotationNo: quotationNo,
        quotationDate: quotationDate, newStatus: newStatus, userId: userId,
      );
}
