import 'dart:async';
import '../../../../core/database/datasources/generic_lookup_local_ds.dart';
import '../../domain/repositories/grn_repository.dart';
import '../datasources/grn_remote_ds.dart';
import '../datasources/grn_local_ds.dart';
import '../models/grn_charge_line_model.dart';
import '../models/grn_line_model.dart';
import '../models/grn_model.dart';

class GrnRepositoryImpl implements GrnRepository {
  final GrnRemoteDs           _remote;
  final GrnLocalDs?           _local;       // null on Flutter Web (no Drift)
  final GenericLookupLocalDs? _lookupLocal; // null on Flutter Web (no Drift)
  final bool                  _isOffline;
  final String                _clientId;
  final String                _companyId;

  GrnRepositoryImpl(
    this._remote,
    this._local,
    this._lookupLocal,
    this._isOffline,
    this._clientId,
    this._companyId,
  );

  Future<List<Map<String, dynamic>>> _cachedLookup({
    required String cacheKey,
    required Future<List<Map<String, dynamic>>> Function() fetchRemote,
  }) async {
    if (_isOffline && _lookupLocal != null) {
      return _lookupLocal.getLookups(cacheKey: cacheKey, clientId: _clientId, companyId: _companyId);
    }
    final rows = await fetchRemote();
    if (_lookupLocal != null) {
      unawaited(_lookupLocal.upsertLookups(
        cacheKey: cacheKey,
        rows: rows,
        idOf: (r) => r['id'] as String,
        clientId: _clientId,
        companyId: _companyId,
      ));
    }
    return rows;
  }

  @override
  Future<List<GrnModel>> listGrns({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) {
    if (_isOffline && _local != null) {
      return _local.listGrns(
        clientId: clientId, companyId: companyId,
        search: search, status: status, limit: limit, offset: offset,
      );
    }
    return _remote.listGrns(
      clientId: clientId, companyId: companyId,
      search: search, status: status, limit: limit, offset: offset,
    );
  }

  @override
  Future<GrnModel?> getHeader({
    required String clientId,
    required String companyId,
    required String grnNo,
    String? grnDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getHeader(clientId: clientId, companyId: companyId, grnNo: grnNo, grnDate: grnDate);
    }
    final header = await _remote.getHeader(clientId: clientId, companyId: companyId, grnNo: grnNo, grnDate: grnDate);
    if (header != null && _local != null) unawaited(_local.cacheHeader(header));
    return header;
  }

  @override
  Future<List<GrnLineModel>> getLines({
    required String clientId,
    required String companyId,
    required String grnNo,
    required String grnDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getLines(clientId: clientId, companyId: companyId, grnNo: grnNo, grnDate: grnDate);
    }
    final lines = await _remote.getLines(clientId: clientId, companyId: companyId, grnNo: grnNo, grnDate: grnDate);
    if (_local != null) unawaited(_local.cacheLines(clientId, companyId, grnNo, grnDate, lines));
    return lines;
  }

  @override
  Future<List<GrnChargeLineModel>> getCharges({
    required String clientId,
    required String companyId,
    required String grnNo,
    required String grnDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getCharges(clientId: clientId, companyId: companyId, grnNo: grnNo, grnDate: grnDate);
    }
    final charges = await _remote.getCharges(clientId: clientId, companyId: companyId, grnNo: grnNo, grnDate: grnDate);
    if (_local != null) unawaited(_local.cacheCharges(clientId, companyId, grnNo, grnDate, charges));
    return charges;
  }

  @override
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required List<Map<String, dynamic>> charges,
    required String userId,
  }) => _remote.save(header: header, lines: lines, batches: batches, serials: serials, charges: charges, userId: userId);

  @override
  Future<void> cacheGrnLocally({
    required String effectiveGrnNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required List<Map<String, dynamic>> charges,
  }) => _local?.cacheFromMaps(effectiveGrnNo, header, lines, batches, serials, charges) ?? Future.value();

  @override
  Future<void> approve({
    required String clientId,
    required String companyId,
    required String grnNo,
    required String grnDate,
    required String approvedBy,
  }) => _remote.approve(clientId: clientId, companyId: companyId, grnNo: grnNo, grnDate: grnDate, approvedBy: approvedBy);

  @override
  Future<List<Map<String, dynamic>>> getOpenPurchaseOrdersForSupplier({
    required String clientId,
    required String companyId,
    required String supplierId,
  }) => _remote.getOpenPurchaseOrdersForSupplier(clientId: clientId, companyId: companyId, supplierId: supplierId);

  @override
  Future<List<Map<String, dynamic>>> getPendingPoLines({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  }) => _remote.getPendingPoLines(clientId: clientId, companyId: companyId, orderNo: orderNo, orderDate: orderDate);

  @override
  Future<List<Map<String, dynamic>>> getPoChargeLinesForOrder({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  }) => _remote.getPoChargeLinesForOrder(clientId: clientId, companyId: companyId, orderNo: orderNo, orderDate: orderDate);

  @override
  Future<List<Map<String, dynamic>>> getAdditionalCharges({
    required String clientId,
    required String companyId,
  }) => _cachedLookup(
        cacheKey: 'GRN_ADDITIONAL_CHARGES',
        fetchRemote: () => _remote.getAdditionalCharges(clientId: clientId, companyId: companyId),
      );

  @override
  Future<List<Map<String, dynamic>>> getProductsForPicker({
    required String clientId,
    required String companyId,
    String? search,
  }) async {
    if (_isOffline && _lookupLocal != null) {
      final all = await _lookupLocal.getLookups(cacheKey: 'GRN_PRODUCT_PICKER', clientId: clientId, companyId: companyId);
      if (search == null || search.isEmpty) return all;
      final s = search.toLowerCase();
      return all.where((p) =>
          (p['product_code'] as String? ?? '').toLowerCase().contains(s) ||
          (p['product_name'] as String? ?? '').toLowerCase().contains(s)).toList();
    }
    final rows = await _remote.getProductsForPicker(clientId: clientId, companyId: companyId, search: search);
    if (_lookupLocal != null && (search == null || search.isEmpty)) {
      unawaited(_lookupLocal.upsertLookups(
        cacheKey: 'GRN_PRODUCT_PICKER', rows: rows, idOf: (r) => r['id'] as String,
        clientId: clientId, companyId: companyId,
      ));
    }
    return rows;
  }

  @override
  Future<Map<String, dynamic>?> getProductByBarcode({
    required String clientId,
    required String companyId,
    required String barcode,
  }) => _remote.getProductByBarcode(clientId: clientId, companyId: companyId, barcode: barcode);

  @override
  Future<List<Map<String, dynamic>>> getCommonMastersByType({
    required String clientId,
    required String companyId,
    required String typeKey,
  }) => _cachedLookup(
        cacheKey: 'GRN_COMMON_MASTERS_$typeKey',
        fetchRemote: () => _remote.getCommonMastersByType(clientId: clientId, companyId: companyId, typeKey: typeKey),
      );

  @override
  Future<List<Map<String, dynamic>>> getTaxGroups({
    required String clientId,
    required String companyId,
  }) => _cachedLookup(
        cacheKey: 'GRN_TAX_GROUPS',
        fetchRemote: () => _remote.getTaxGroups(clientId: clientId, companyId: companyId),
      );

  @override
  Future<Map<String, List<String>>> getTaxGroupMemberTaxIds(List<String> groupIds) =>
      _remote.getTaxGroupMemberTaxIds(groupIds);

  @override
  Future<Map<String, double>> getTaxRatesByIds({
    required List<String> taxIds,
    required String asOfDate,
  }) => _remote.getTaxRatesByIds(taxIds: taxIds, asOfDate: asOfDate);

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
