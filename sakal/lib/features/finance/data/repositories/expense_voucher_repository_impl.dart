import '../../domain/repositories/expense_voucher_repository.dart';
import '../datasources/expense_voucher_remote_ds.dart';
import '../datasources/expense_voucher_local_ds.dart';

class ExpenseVoucherRepositoryImpl implements ExpenseVoucherRepository {
  final ExpenseVoucherRemoteDs _remote;
  final ExpenseVoucherLocalDs? _local; // null on Flutter Web (no Drift)
  final bool _isOffline;

  ExpenseVoucherRepositoryImpl(this._remote, this._local, this._isOffline);

  @override
  Future<List<Map<String, dynamic>>> listVouchers({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int limit = 50,
    int offset = 0,
  }) {
    if (_isOffline && _local != null) {
      return _local.listVouchers(clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset);
    }
    return _remote.listVouchers(clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset);
  }

  @override
  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String transNo,
  }) {
    if (_isOffline && _local != null) {
      return _local.getHeader(clientId: clientId, companyId: companyId, transNo: transNo);
    }
    return _remote.getHeader(clientId: clientId, companyId: companyId, transNo: transNo);
  }

  @override
  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String transNo,
    required String transDate,
  }) {
    if (_isOffline && _local != null) {
      return _local.getLines(clientId: clientId, companyId: companyId, transNo: transNo, transDate: transDate);
    }
    return _remote.getLines(clientId: clientId, companyId: companyId, transNo: transNo, transDate: transDate);
  }

  // Everything below is online-only — same reasoning as every other
  // module's own live-lookup methods (a live pending-bills/exchange-rate
  // read is meaningless against a stale offline replica).
  @override
  Future<Map<String, dynamic>> getCompanyCurrencies({required String companyId}) =>
      _remote.getCompanyCurrencies(companyId: companyId);

  @override
  Future<double?> getExchangeRate({
    required String companyId,
    required String locationId,
    required String fromCurrency,
    required String toCurrency,
    required String rateDate,
  }) => _remote.getExchangeRate(companyId: companyId, locationId: locationId, fromCurrency: fromCurrency, toCurrency: toCurrency, rateDate: rateDate);

  @override
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required String userId,
  }) => _remote.save(header: header, lines: lines, userId: userId);

  @override
  Future<void> approve({
    required String clientId,
    required String companyId,
    required String locationId,
    required String transNo,
    required String transDate,
    required String approvedBy,
  }) => _remote.approve(clientId: clientId, companyId: companyId, locationId: locationId, transNo: transNo, transDate: transDate, approvedBy: approvedBy);

  @override
  Future<Map<String, List<String>>> getTaxGroupMemberTaxIds(List<String> groupIds) =>
      _remote.getTaxGroupMemberTaxIds(groupIds);

  @override
  Future<Map<String, double>> getTaxRatesByIds({
    required List<String> taxIds,
    required String asOfDate,
  }) => _remote.getTaxRatesByIds(taxIds: taxIds, asOfDate: asOfDate);

  @override
  Future<Map<String, bool>> getTaxWithholdingFlags(List<String> taxIds) =>
      _remote.getTaxWithholdingFlags(taxIds);

  @override
  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String transNo,
  }) => _remote.getPostedVouchers(clientId: clientId, companyId: companyId, transNo: transNo);

  @override
  Future<void> cacheVoucherLocally({
    required String effectiveTransNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
  }) => _local?.cacheFromMaps(effectiveTransNo, header, lines) ?? Future.value();
}
