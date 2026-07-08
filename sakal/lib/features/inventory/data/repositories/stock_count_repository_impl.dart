import 'dart:async';
import '../../domain/repositories/stock_count_repository.dart';
import '../datasources/stock_count_remote_ds.dart';
import '../datasources/stock_count_local_ds.dart';

class StockCountRepositoryImpl implements StockCountRepository {
  final StockCountRemoteDs _remote;
  final StockCountLocalDs? _local; // null on Flutter Web (no Drift)
  final bool _isOffline;

  StockCountRepositoryImpl(this._remote, this._local, this._isOffline);

  @override
  Future<List<Map<String, dynamic>>> listStockCounts({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) {
    if (_isOffline && _local != null) {
      return _local.listStockCounts(clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset);
    }
    return _remote.listStockCounts(clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset);
  }

  @override
  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String countNo,
    String? countDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getHeader(clientId: clientId, companyId: companyId, countNo: countNo, countDate: countDate);
    }
    final header = await _remote.getHeader(clientId: clientId, companyId: companyId, countNo: countNo, countDate: countDate);
    if (header != null && _local != null) unawaited(_local.cacheHeader(header));
    return header;
  }

  @override
  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String countNo,
    required String countDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getLines(clientId: clientId, companyId: companyId, countNo: countNo, countDate: countDate);
    }
    final lines = await _remote.getLines(clientId: clientId, companyId: companyId, countNo: countNo, countDate: countDate);
    if (_local != null) unawaited(_local.cacheLines(clientId, companyId, countNo, countDate, lines));
    return lines;
  }

  @override
  Future<List<Map<String, dynamic>>> getLineBatches({
    required String clientId,
    required String companyId,
    required String countNo,
    required String countDate,
    required int    lineSerial,
  }) {
    if (_isOffline && _local != null) {
      return _local.getLineBatches(clientId: clientId, companyId: companyId, countNo: countNo, countDate: countDate, lineSerial: lineSerial);
    }
    return _remote.getLineBatches(clientId: clientId, companyId: companyId, countNo: countNo, countDate: countDate, lineSerial: lineSerial);
  }

  @override
  Future<List<Map<String, dynamic>>> getLineSerials({
    required String clientId,
    required String companyId,
    required String countNo,
    required String countDate,
    required int    lineSerial,
  }) {
    if (_isOffline && _local != null) {
      return _local.getLineSerials(clientId: clientId, companyId: companyId, countNo: countNo, countDate: countDate, lineSerial: lineSerial);
    }
    return _remote.getLineSerials(clientId: clientId, companyId: companyId, countNo: countNo, countDate: countDate, lineSerial: lineSerial);
  }

  @override
  Future<List<Map<String, dynamic>>> getLocations({
    required String clientId,
    required String companyId,
  }) => _remote.getLocations(clientId: clientId, companyId: companyId);

  @override
  Future<List<Map<String, dynamic>>> getEligibleProducts({
    required String clientId,
    required String companyId,
    String? categoryId,
    String? nature,
  }) => _remote.getEligibleProducts(clientId: clientId, companyId: companyId, categoryId: categoryId, nature: nature);

  @override
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required String userId,
  }) => _remote.save(header: header, lines: lines, batches: batches, serials: serials, userId: userId);

  @override
  Future<void> cacheStockCountLocally({
    required String effectiveCountNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
  }) => _local?.cacheFromMaps(effectiveCountNo, header, lines, batches, serials) ?? Future.value();

  @override
  Future<void> submit({
    required String clientId,
    required String companyId,
    required String countNo,
    required String countDate,
    required String userId,
  }) => _remote.submit(clientId: clientId, companyId: companyId, countNo: countNo, countDate: countDate, userId: userId);
}
