import 'dart:async';
import '../../domain/repositories/price_master_repository.dart';
import '../datasources/price_master_remote_ds.dart';
import '../datasources/price_master_local_ds.dart';

class PriceMasterRepositoryImpl implements PriceMasterRepository {
  final PriceMasterRemoteDs _remote;
  final PriceMasterLocalDs? _local; // null on Flutter Web (no Drift)
  final bool _isOffline;

  PriceMasterRepositoryImpl(this._remote, this._local, this._isOffline);

  @override
  Future<List<Map<String, dynamic>>> listBatches({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    String? priceType,
    String? locationId,
    int     limit  = 50,
    int     offset = 0,
  }) {
    if (_isOffline && _local != null) {
      return _local.listBatches(
        clientId: clientId, companyId: companyId, search: search, status: status,
        priceType: priceType, locationId: locationId, limit: limit, offset: offset,
      );
    }
    return _remote.listBatches(
      clientId: clientId, companyId: companyId, search: search, status: status,
      priceType: priceType, locationId: locationId, limit: limit, offset: offset,
    );
  }

  @override
  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String entryNo,
    String? entryDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getHeader(clientId: clientId, companyId: companyId, entryNo: entryNo, entryDate: entryDate);
    }
    final header = await _remote.getHeader(clientId: clientId, companyId: companyId, entryNo: entryNo, entryDate: entryDate);
    if (header != null && _local != null) unawaited(_local.cacheHeader(header));
    return header;
  }

  @override
  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String entryNo,
    required String entryDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getLines(clientId: clientId, companyId: companyId, entryNo: entryNo, entryDate: entryDate);
    }
    final lines = await _remote.getLines(clientId: clientId, companyId: companyId, entryNo: entryNo, entryDate: entryDate);
    if (_local != null) unawaited(_local.cacheLines(clientId, companyId, entryNo, entryDate, lines));
    return lines;
  }

  @override
  Future<List<Map<String, dynamic>>> getProductsForPicker({
    required String clientId,
    required String companyId,
    String? search,
  }) => _remote.getProductsForPicker(clientId: clientId, companyId: companyId, search: search);

  @override
  Future<List<Map<String, dynamic>>> getProductUoms(String productId) => _remote.getProductUoms(productId);

  @override
  Future<List<Map<String, dynamic>>> getReasons({
    required String clientId,
    required String companyId,
  }) => _remote.getReasons(clientId: clientId, companyId: companyId);

  @override
  Future<Map<String, dynamic>?> getProductByCode({
    required String clientId,
    required String companyId,
    required String code,
    required bool tryPartNumber,
  }) => _remote.getProductByCode(clientId: clientId, companyId: companyId, code: code, tryPartNumber: tryPartNumber);

  @override
  Future<Map<String, dynamic>?> getProductLocationCost({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) => _remote.getProductLocationCost(clientId: clientId, companyId: companyId, locationId: locationId, productId: productId);

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
    required String userId,
  }) => _remote.save(header: header, lines: lines, userId: userId);

  @override
  Future<void> cacheBatchLocally({
    required String effectiveEntryNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
  }) => _local?.cacheFromMaps(effectiveEntryNo, header, lines) ?? Future.value();

  @override
  Future<void> approve({
    required String clientId,
    required String companyId,
    required String entryNo,
    required String entryDate,
    required String approvedBy,
  }) => _remote.approve(
        clientId: clientId, companyId: companyId, entryNo: entryNo,
        entryDate: entryDate, approvedBy: approvedBy,
      );
}
