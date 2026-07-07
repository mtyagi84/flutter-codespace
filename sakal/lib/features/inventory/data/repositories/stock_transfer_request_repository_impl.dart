import 'dart:async';
import '../../domain/repositories/stock_transfer_request_repository.dart';
import '../datasources/stock_transfer_request_remote_ds.dart';
import '../datasources/stock_transfer_request_local_ds.dart';

class StockTransferRequestRepositoryImpl implements StockTransferRequestRepository {
  final StockTransferRequestRemoteDs _remote;
  final StockTransferRequestLocalDs? _local; // null on Flutter Web (no Drift)
  final bool _isOffline;

  StockTransferRequestRepositoryImpl(this._remote, this._local, this._isOffline);

  @override
  Future<List<Map<String, dynamic>>> listRequests({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) {
    if (_isOffline && _local != null) {
      return _local.listRequests(
        clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset,
      );
    }
    return _remote.listRequests(
      clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset,
    );
  }

  @override
  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String requestNo,
    String? requestDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getHeader(clientId: clientId, companyId: companyId, requestNo: requestNo, requestDate: requestDate);
    }
    final header = await _remote.getHeader(clientId: clientId, companyId: companyId, requestNo: requestNo, requestDate: requestDate);
    if (header != null && _local != null) unawaited(_local.cacheHeader(header));
    return header;
  }

  @override
  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String requestNo,
    required String requestDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getLines(clientId: clientId, companyId: companyId, requestNo: requestNo, requestDate: requestDate);
    }
    final lines = await _remote.getLines(clientId: clientId, companyId: companyId, requestNo: requestNo, requestDate: requestDate);
    if (_local != null) unawaited(_local.cacheLines(clientId, companyId, requestNo, requestDate, lines));
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
  Future<Map<String, dynamic>?> getProductByBarcode({
    required String clientId,
    required String companyId,
    required String barcode,
  }) => _remote.getProductByBarcode(clientId: clientId, companyId: companyId, barcode: barcode);

  @override
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required String userId,
  }) => _remote.save(header: header, lines: lines, userId: userId);

  @override
  Future<void> cacheRequestLocally({
    required String effectiveRequestNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
  }) => _local?.cacheFromMaps(effectiveRequestNo, header, lines) ?? Future.value();

  @override
  Future<void> approve({
    required String clientId,
    required String companyId,
    required String requestNo,
    required String requestDate,
    required String approvedBy,
  }) => _remote.approve(
        clientId: clientId, companyId: companyId, requestNo: requestNo,
        requestDate: requestDate, approvedBy: approvedBy,
      );
}
