import 'dart:async';
import '../../domain/repositories/finance_voucher_repository.dart';
import '../datasources/finance_voucher_remote_ds.dart';
import '../datasources/finance_voucher_local_ds.dart';
import '../models/finance_voucher_model.dart';

class FinanceVoucherRepositoryImpl implements FinanceVoucherRepository {
  final FinanceVoucherRemoteDs  _remote;
  final FinanceVoucherLocalDs?  _local;   // null on Flutter Web (no Drift)
  final bool                    _isOffline;

  FinanceVoucherRepositoryImpl(this._remote, this._local, this._isOffline);

  @override
  Future<List<Map<String, dynamic>>> listHeaders({
    required String clientId,
    required String companyId,
    required String locationId,
    required String fromDate,
    required String toDate,
    String? voucherTypeCode,
    bool? isPosted,
  }) {
    if (_isOffline && _local != null) {
      return _local.listHeaders(
        clientId: clientId, companyId: companyId, locationId: locationId,
        fromDate: fromDate, toDate: toDate,
        voucherTypeCode: voucherTypeCode, isPosted: isPosted,
      );
    }
    // Online: remote is the source of truth for browsing history. Offline-created
    // (not-yet-synced) vouchers are already cached via cacheVoucherLocally and
    // don't need caching again here — per the offline design, transaction history
    // browsing isn't guaranteed offline, only newly-created docs are.
    return _remote.listHeaders(
      clientId: clientId, companyId: companyId, locationId: locationId,
      fromDate: fromDate, toDate: toDate,
      voucherTypeCode: voucherTypeCode, isPosted: isPosted,
    );
  }

  @override
  Future<FinanceVoucherHeader?> getHeader({
    required String clientId,
    required String companyId,
    required String transNo,
    String? transDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getHeader(
        clientId:  clientId,
        companyId: companyId,
        transNo:   transNo,
        transDate: transDate,
      );
    }
    final header = await _remote.getHeader(
      clientId:  clientId,
      companyId: companyId,
      transNo:   transNo,
      transDate: transDate,
    );
    if (header != null && _local != null) unawaited(_local.cacheHeader(header));
    return header;
  }

  @override
  Future<List<FinanceVoucherLine>> getLines({
    required String clientId,
    required String companyId,
    required String transNo,
    required String transDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getLines(
        clientId:  clientId,
        companyId: companyId,
        transNo:   transNo,
        transDate: transDate,
      );
    }
    final lines = await _remote.getLines(
      clientId:  clientId,
      companyId: companyId,
      transNo:   transNo,
      transDate: transDate,
    );
    if (_local != null) unawaited(_local.cacheLines(clientId, companyId, transNo, transDate, lines));
    return lines;
  }

  @override
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required String userId,
  }) => _remote.save(header: header, lines: lines, userId: userId);

  @override
  Future<void> cacheVoucherLocally({
    required String effectiveTransNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
  }) => _local?.cacheFromMaps(effectiveTransNo, header, lines) ?? Future.value();

  @override
  Future<void> post({
    required String clientId,
    required String companyId,
    required String locationId,
    required String transNo,
    required String transDate,
    required String postedBy,
  }) => _remote.post(
        clientId:   clientId,
        companyId:  companyId,
        locationId: locationId,
        transNo:    transNo,
        transDate:  transDate,
        postedBy:   postedBy,
      );

  @override
  Future<List<Map<String, dynamic>>> getPendingBills({
    required String companyId,
    required String locationId,
    required String accountId,
  }) => _remote.getPendingBills(
        companyId:  companyId,
        locationId: locationId,
        accountId:  accountId,
      );

  @override
  Future<double?> fetchExchangeRate({
    required String companyId,
    required String locationId,
    required String fromCurrency,
    required String toCurrency,
    required String rateDate,
  }) => _remote.getExchangeRate(
        companyId:    companyId,
        locationId:   locationId,
        fromCurrency: fromCurrency,
        toCurrency:   toCurrency,
        rateDate:     rateDate,
      );
}
