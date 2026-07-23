import '../../domain/repositories/cash_receipt_repository.dart';
import '../datasources/cash_receipt_remote_ds.dart';
import '../datasources/cash_receipt_local_ds.dart';

class CashReceiptRepositoryImpl implements CashReceiptRepository {
  final CashReceiptRemoteDs _remote;
  final CashReceiptLocalDs? _local; // null on Flutter Web (no Drift)
  final bool _isOffline;

  CashReceiptRepositoryImpl(this._remote, this._local, this._isOffline);

  @override
  Future<List<Map<String, dynamic>>> listReceipts({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int limit = 50,
    int offset = 0,
  }) {
    if (_isOffline && _local != null) {
      return _local.listReceipts(clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset);
    }
    return _remote.listReceipts(clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset);
  }

  @override
  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String receiptNo,
  }) {
    if (_isOffline && _local != null) {
      return _local.getHeader(clientId: clientId, companyId: companyId, receiptNo: receiptNo);
    }
    return _remote.getHeader(clientId: clientId, companyId: companyId, receiptNo: receiptNo);
  }

  @override
  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String receiptNo,
    required String receiptDate,
  }) {
    if (_isOffline && _local != null) {
      return _local.getLines(clientId: clientId, companyId: companyId, receiptNo: receiptNo, receiptDate: receiptDate);
    }
    return _remote.getLines(clientId: clientId, companyId: companyId, receiptNo: receiptNo, receiptDate: receiptDate);
  }

  // Everything below is online-only — a live pending-bills read is
  // meaningless against a stale offline replica (another device could
  // have already settled the same bill), same reasoning every prior
  // module's picker/candidate reads already established.
  @override
  Future<Map<String, dynamic>?> getQuickInvoiceSetup({
    required String clientId,
    required String companyId,
    required String userId,
  }) => _remote.getQuickInvoiceSetup(clientId: clientId, companyId: companyId, userId: userId);

  @override
  Future<List<Map<String, dynamic>>> getCustomersWithPendingBills({
    required String clientId,
    required String companyId,
    required String locationId,
    String? search,
  }) => _remote.getCustomersWithPendingBills(clientId: clientId, companyId: companyId, locationId: locationId, search: search);

  @override
  Future<List<Map<String, dynamic>>> getPendingBills({
    required String companyId,
    required String locationId,
    required String accountId,
  }) => _remote.getPendingBills(companyId: companyId, locationId: locationId, accountId: accountId);

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
    required String receiptNo,
    required String receiptDate,
    required String approvedBy,
  }) => _remote.approve(clientId: clientId, companyId: companyId, receiptNo: receiptNo, receiptDate: receiptDate, approvedBy: approvedBy);

  @override
  Future<List<Map<String, dynamic>>> listDraftReceiptsForReview({
    required String clientId,
    required String companyId,
    required String locationId,
  }) => _remote.listDraftReceiptsForReview(clientId: clientId, companyId: companyId, locationId: locationId);

  @override
  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String receiptNo,
  }) => _remote.getPostedVouchers(clientId: clientId, companyId: companyId, receiptNo: receiptNo);

  @override
  Future<List<Map<String, dynamic>>> getPostedVoucherLines({
    required String clientId,
    required String companyId,
    required String voucherNo,
    required String voucherDate,
  }) => _remote.getPostedVoucherLines(clientId: clientId, companyId: companyId, voucherNo: voucherNo, voucherDate: voucherDate);

  @override
  Future<List<Map<String, dynamic>>> getUsersForAutocomplete({
    required String clientId,
    required String companyId,
  }) => _remote.getUsersForAutocomplete(clientId: clientId, companyId: companyId);

  @override
  Future<void> cacheReceiptLocally({
    required String effectiveReceiptNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
  }) => _local?.cacheFromMaps(effectiveReceiptNo, header, lines) ?? Future.value();
}
