import 'dart:async';
import '../../domain/repositories/stock_adjustment_repository.dart';
import '../datasources/stock_adjustment_remote_ds.dart';
import '../datasources/stock_adjustment_local_ds.dart';

class StockAdjustmentRepositoryImpl implements StockAdjustmentRepository {
  final StockAdjustmentRemoteDs _remote;
  final StockAdjustmentLocalDs? _local; // null on Flutter Web (no Drift)
  final bool _isOffline;

  StockAdjustmentRepositoryImpl(this._remote, this._local, this._isOffline);

  @override
  Future<List<Map<String, dynamic>>> listAdjustments({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) {
    if (_isOffline && _local != null) {
      return _local.listAdjustments(clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset);
    }
    return _remote.listAdjustments(clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset);
  }

  @override
  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String adjustmentNo,
    String? adjustmentDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getHeader(clientId: clientId, companyId: companyId, adjustmentNo: adjustmentNo, adjustmentDate: adjustmentDate);
    }
    final header = await _remote.getHeader(clientId: clientId, companyId: companyId, adjustmentNo: adjustmentNo, adjustmentDate: adjustmentDate);
    if (header != null && _local != null) unawaited(_local.cacheHeader(header));
    return header;
  }

  @override
  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String adjustmentNo,
    required String adjustmentDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getLines(clientId: clientId, companyId: companyId, adjustmentNo: adjustmentNo, adjustmentDate: adjustmentDate);
    }
    final lines = await _remote.getLines(clientId: clientId, companyId: companyId, adjustmentNo: adjustmentNo, adjustmentDate: adjustmentDate);
    if (_local != null) unawaited(_local.cacheLines(clientId, companyId, adjustmentNo, adjustmentDate, lines));
    return lines;
  }

  @override
  Future<List<Map<String, dynamic>>> getLineBatches({
    required String clientId,
    required String companyId,
    required String adjustmentNo,
    required String adjustmentDate,
    required int    lineSerial,
  }) {
    if (_isOffline && _local != null) {
      return _local.getLineBatches(clientId: clientId, companyId: companyId, adjustmentNo: adjustmentNo, adjustmentDate: adjustmentDate, lineSerial: lineSerial);
    }
    return _remote.getLineBatches(clientId: clientId, companyId: companyId, adjustmentNo: adjustmentNo, adjustmentDate: adjustmentDate, lineSerial: lineSerial);
  }

  @override
  Future<List<Map<String, dynamic>>> getLineSerials({
    required String clientId,
    required String companyId,
    required String adjustmentNo,
    required String adjustmentDate,
    required int    lineSerial,
  }) {
    if (_isOffline && _local != null) {
      return _local.getLineSerials(clientId: clientId, companyId: companyId, adjustmentNo: adjustmentNo, adjustmentDate: adjustmentDate, lineSerial: lineSerial);
    }
    return _remote.getLineSerials(clientId: clientId, companyId: companyId, adjustmentNo: adjustmentNo, adjustmentDate: adjustmentDate, lineSerial: lineSerial);
  }

  @override
  Future<List<Map<String, dynamic>>> getLocations({
    required String clientId,
    required String companyId,
  }) => _remote.getLocations(clientId: clientId, companyId: companyId);

  @override
  Future<List<Map<String, dynamic>>> getReasons({
    required String clientId,
    required String companyId,
  }) => _remote.getReasons(clientId: clientId, companyId: companyId);

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
  Future<num> getCurrentStock({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) => _remote.getCurrentStock(clientId: clientId, companyId: companyId, locationId: locationId, productId: productId);

  @override
  Future<List<Map<String, dynamic>>> getAvailableBatches({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) => _remote.getAvailableBatches(clientId: clientId, companyId: companyId, locationId: locationId, productId: productId);

  @override
  Future<List<Map<String, dynamic>>> getAvailableSerials({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) => _remote.getAvailableSerials(clientId: clientId, companyId: companyId, locationId: locationId, productId: productId);

  @override
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required String userId,
  }) => _remote.save(header: header, lines: lines, batches: batches, serials: serials, userId: userId);

  @override
  Future<void> cacheAdjustmentLocally({
    required String effectiveAdjustmentNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
  }) => _local?.cacheFromMaps(effectiveAdjustmentNo, header, lines, batches, serials) ?? Future.value();

  @override
  Future<void> approve({
    required String clientId,
    required String companyId,
    required String adjustmentNo,
    required String adjustmentDate,
    required String approvedBy,
  }) => _remote.approve(clientId: clientId, companyId: companyId, adjustmentNo: adjustmentNo, adjustmentDate: adjustmentDate, approvedBy: approvedBy);

  @override
  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String adjustmentNo,
  }) => _remote.getPostedVouchers(clientId: clientId, companyId: companyId, adjustmentNo: adjustmentNo);

  @override
  Future<List<Map<String, dynamic>>> getPostedVoucherLines({
    required String clientId,
    required String companyId,
    required String voucherNo,
    required String voucherDate,
  }) => _remote.getPostedVoucherLines(clientId: clientId, companyId: companyId, voucherNo: voucherNo, voucherDate: voucherDate);
}
