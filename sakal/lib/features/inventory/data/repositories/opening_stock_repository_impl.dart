import 'dart:async';
import '../../domain/repositories/opening_stock_repository.dart';
import '../datasources/opening_stock_remote_ds.dart';
import '../datasources/opening_stock_local_ds.dart';

class OpeningStockRepositoryImpl implements OpeningStockRepository {
  final OpeningStockRemoteDs _remote;
  final OpeningStockLocalDs? _local; // null on Flutter Web (no Drift)
  final bool _isOffline;

  OpeningStockRepositoryImpl(this._remote, this._local, this._isOffline);

  @override
  Future<List<Map<String, dynamic>>> listOpeningStocks({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) {
    if (_isOffline && _local != null) {
      return _local.listOpeningStocks(clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset);
    }
    return _remote.listOpeningStocks(clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset);
  }

  @override
  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String openingNo,
    String? openingDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getHeader(clientId: clientId, companyId: companyId, openingNo: openingNo, openingDate: openingDate);
    }
    final header = await _remote.getHeader(clientId: clientId, companyId: companyId, openingNo: openingNo, openingDate: openingDate);
    if (header != null && _local != null) unawaited(_local.cacheHeader(header));
    return header;
  }

  @override
  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String openingNo,
    required String openingDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getLines(clientId: clientId, companyId: companyId, openingNo: openingNo, openingDate: openingDate);
    }
    final lines = await _remote.getLines(clientId: clientId, companyId: companyId, openingNo: openingNo, openingDate: openingDate);
    if (_local != null) unawaited(_local.cacheLines(clientId, companyId, openingNo, openingDate, lines));
    return lines;
  }

  @override
  Future<List<Map<String, dynamic>>> getLocations({
    required String clientId,
    required String companyId,
  }) => _remote.getLocations(clientId: clientId, companyId: companyId);

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
  Future<Map<String, dynamic>?> getCurrentStockAndCost({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) => _remote.getCurrentStockAndCost(clientId: clientId, companyId: companyId, locationId: locationId, productId: productId);

  @override
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required String userId,
  }) => _remote.save(header: header, lines: lines, userId: userId);

  @override
  Future<void> cacheOpeningStockLocally({
    required String effectiveOpeningNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
  }) => _local?.cacheFromMaps(effectiveOpeningNo, header, lines) ?? Future.value();

  @override
  Future<void> approve({
    required String clientId,
    required String companyId,
    required String openingNo,
    required String openingDate,
    required String approvedBy,
  }) => _remote.approve(clientId: clientId, companyId: companyId, openingNo: openingNo, openingDate: openingDate, approvedBy: approvedBy);
}
