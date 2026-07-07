import 'dart:async';
import '../../domain/repositories/stock_transfer_repository.dart';
import '../datasources/stock_transfer_remote_ds.dart';
import '../datasources/stock_transfer_local_ds.dart';

class StockTransferRepositoryImpl implements StockTransferRepository {
  final StockTransferRemoteDs _remote;
  final StockTransferLocalDs? _local; // null on Flutter Web (no Drift)
  final bool _isOffline;

  StockTransferRepositoryImpl(this._remote, this._local, this._isOffline);

  @override
  Future<List<Map<String, dynamic>>> listTransfers({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) {
    if (_isOffline && _local != null) {
      return _local.listTransfers(
        clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset,
      );
    }
    return _remote.listTransfers(
      clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset,
    );
  }

  @override
  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String transferNo,
    String? transferDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getHeader(clientId: clientId, companyId: companyId, transferNo: transferNo, transferDate: transferDate);
    }
    final header = await _remote.getHeader(clientId: clientId, companyId: companyId, transferNo: transferNo, transferDate: transferDate);
    if (header != null && _local != null) unawaited(_local.cacheHeader(header));
    return header;
  }

  @override
  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String transferNo,
    required String transferDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getLines(clientId: clientId, companyId: companyId, transferNo: transferNo, transferDate: transferDate);
    }
    final lines = await _remote.getLines(clientId: clientId, companyId: companyId, transferNo: transferNo, transferDate: transferDate);
    if (_local != null) unawaited(_local.cacheLines(clientId, companyId, transferNo, transferDate, lines));
    return lines;
  }

  @override
  Future<List<Map<String, dynamic>>> getCharges({
    required String clientId,
    required String companyId,
    required String transferNo,
    required String transferDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getCharges(clientId: clientId, companyId: companyId, transferNo: transferNo, transferDate: transferDate);
    }
    final charges = await _remote.getCharges(clientId: clientId, companyId: companyId, transferNo: transferNo, transferDate: transferDate);
    if (_local != null) unawaited(_local.cacheCharges(clientId, companyId, transferNo, transferDate, charges));
    return charges;
  }

  @override
  Future<List<Map<String, dynamic>>> getLocations({
    required String clientId,
    required String companyId,
  }) => _remote.getLocations(clientId: clientId, companyId: companyId);

  @override
  Future<String> getInterLocationModel({
    required String clientId,
    required String companyId,
  }) => _remote.getInterLocationModel(clientId: clientId, companyId: companyId);

  @override
  Future<List<Map<String, dynamic>>> getFulfillableRequests({
    required String clientId,
    required String companyId,
    required String fromLocationId,
  }) => _remote.getFulfillableRequests(clientId: clientId, companyId: companyId, fromLocationId: fromLocationId);

  @override
  Future<List<Map<String, dynamic>>> getRequestLines({
    required String clientId,
    required String companyId,
    required String requestNo,
    required String requestDate,
  }) => _remote.getRequestLines(clientId: clientId, companyId: companyId, requestNo: requestNo, requestDate: requestDate);

  @override
  Future<List<Map<String, dynamic>>> getProductsForPicker({
    required String clientId,
    required String companyId,
    String? search,
  }) => _remote.getProductsForPicker(clientId: clientId, companyId: companyId, search: search);

  @override
  Future<List<Map<String, dynamic>>> getAdditionalCharges({
    required String clientId,
    required String companyId,
  }) => _remote.getAdditionalCharges(clientId: clientId, companyId: companyId);

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
  Future<List<Map<String, dynamic>>> getTransferLineBatches({
    required String clientId,
    required String companyId,
    required String transferNo,
    required String transferDate,
    required int    lineSerial,
  }) => _remote.getTransferLineBatches(clientId: clientId, companyId: companyId, transferNo: transferNo, transferDate: transferDate, lineSerial: lineSerial);

  @override
  Future<List<Map<String, dynamic>>> getTransferLineSerials({
    required String clientId,
    required String companyId,
    required String transferNo,
    required String transferDate,
    required int    lineSerial,
  }) => _remote.getTransferLineSerials(clientId: clientId, companyId: companyId, transferNo: transferNo, transferDate: transferDate, lineSerial: lineSerial);

  @override
  Future<Map<String, num>> getCostPrices({
    required String clientId,
    required String companyId,
    required String locationId,
    required List<String> productIds,
  }) => _remote.getCostPrices(clientId: clientId, companyId: companyId, locationId: locationId, productIds: productIds);

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
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required List<Map<String, dynamic>> charges,
    required String userId,
  }) => _remote.save(header: header, lines: lines, batches: batches, serials: serials, charges: charges, userId: userId);

  @override
  Future<void> cacheTransferLocally({
    required String effectiveTransferNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required List<Map<String, dynamic>> charges,
  }) => _local?.cacheFromMaps(effectiveTransferNo, header, lines, batches, serials, charges) ?? Future.value();

  @override
  Future<void> approve({
    required String clientId,
    required String companyId,
    required String transferNo,
    required String transferDate,
    required String approvedBy,
  }) => _remote.approve(
        clientId: clientId, companyId: companyId, transferNo: transferNo,
        transferDate: transferDate, approvedBy: approvedBy,
      );

  @override
  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String transferNo,
  }) => _remote.getPostedVouchers(clientId: clientId, companyId: companyId, transferNo: transferNo);

  @override
  Future<List<Map<String, dynamic>>> getPostedVoucherLines({
    required String clientId,
    required String companyId,
    required String voucherNo,
    required String voucherDate,
  }) => _remote.getPostedVoucherLines(clientId: clientId, companyId: companyId, voucherNo: voucherNo, voucherDate: voucherDate);
}
