import '../../domain/repositories/sales_return_repository.dart';
import '../datasources/sales_return_remote_ds.dart';
import '../datasources/sales_return_local_ds.dart';

/// Offline SAVE only (retrofit, 2026-07-21) — mirrors Sales Invoice's own
/// DIRECT-mode offline pattern. Approve stays online-only always: it needs
/// a live, cross-device "how much of this invoice line has already been
/// returned" check that an offline replica can't safely guarantee, same
/// reasoning as Sales Invoice's own AGAINST_QUOTATION/AGAINST_ORDER modes.
/// Everything picker/candidate-related below stays online-only too — a
/// stale offline replica can't safely serve live "already returned" caps.
class SalesReturnRepositoryImpl implements SalesReturnRepository {
  final SalesReturnRemoteDs _remote;
  final SalesReturnLocalDs? _local; // null on Flutter Web (no Drift)
  final bool _isOffline;

  SalesReturnRepositoryImpl(this._remote, this._local, this._isOffline);

  @override
  Future<List<Map<String, dynamic>>> listReturns({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) {
    if (_isOffline && _local != null) {
      return _local.listReturns(clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset);
    }
    return _remote.listReturns(clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset);
  }

  @override
  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String returnNo,
    String? returnDate,
  }) {
    if (_isOffline && _local != null) {
      return _local.getHeader(clientId: clientId, companyId: companyId, returnNo: returnNo, returnDate: returnDate);
    }
    return _remote.getHeader(clientId: clientId, companyId: companyId, returnNo: returnNo, returnDate: returnDate);
  }

  @override
  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
  }) {
    if (_isOffline && _local != null) {
      return _local.getLines(clientId: clientId, companyId: companyId, returnNo: returnNo, returnDate: returnDate);
    }
    return _remote.getLines(clientId: clientId, companyId: companyId, returnNo: returnNo, returnDate: returnDate);
  }

  @override
  Future<List<Map<String, dynamic>>> getCharges({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
  }) => _remote.getCharges(clientId: clientId, companyId: companyId, returnNo: returnNo, returnDate: returnDate);

  @override
  Future<List<Map<String, dynamic>>> getApprovedInvoices({
    required String clientId,
    required String companyId,
    String? search,
  }) => _remote.getApprovedInvoices(clientId: clientId, companyId: companyId, search: search);

  @override
  Future<List<Map<String, dynamic>>> getInvoiceLines({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  }) => _remote.getInvoiceLines(clientId: clientId, companyId: companyId, invoiceNo: invoiceNo, invoiceDate: invoiceDate);

  @override
  Future<List<Map<String, dynamic>>> getInvoiceCharges({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  }) => _remote.getInvoiceCharges(clientId: clientId, companyId: companyId, invoiceNo: invoiceNo, invoiceDate: invoiceDate);

  @override
  Future<List<Map<String, dynamic>>> getAlreadyReturnedByLine({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  }) => _remote.getAlreadyReturnedByLine(clientId: clientId, companyId: companyId, invoiceNo: invoiceNo, invoiceDate: invoiceDate);

  @override
  Future<List<Map<String, dynamic>>> getInvoiceLineBatches({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
    required int    lineSerial,
  }) => _remote.getInvoiceLineBatches(clientId: clientId, companyId: companyId, invoiceNo: invoiceNo, invoiceDate: invoiceDate, lineSerial: lineSerial);

  @override
  Future<List<Map<String, dynamic>>> getInvoiceLineSerials({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
    required int    lineSerial,
  }) => _remote.getInvoiceLineSerials(clientId: clientId, companyId: companyId, invoiceNo: invoiceNo, invoiceDate: invoiceDate, lineSerial: lineSerial);

  @override
  Future<List<Map<String, dynamic>>> getAlreadyReturnedBatches({
    required String clientId,
    required String companyId,
    required List<String> returnNos,
  }) => _remote.getAlreadyReturnedBatches(clientId: clientId, companyId: companyId, returnNos: returnNos);

  @override
  Future<List<Map<String, dynamic>>> getAlreadyReturnedSerials({
    required String clientId,
    required String companyId,
    required List<String> returnNos,
  }) => _remote.getAlreadyReturnedSerials(clientId: clientId, companyId: companyId, returnNos: returnNos);

  @override
  Future<List<Map<String, dynamic>>> getPriorReturnLineKeys({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  }) => _remote.getPriorReturnLineKeys(clientId: clientId, companyId: companyId, invoiceNo: invoiceNo, invoiceDate: invoiceDate);

  @override
  Future<List<Map<String, dynamic>>> listDraftReturnsForReview({
    required String clientId,
    required String companyId,
    required String locationId,
  }) => _remote.listDraftReturnsForReview(clientId: clientId, companyId: companyId, locationId: locationId);

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
  Future<void> approve({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
    required String approvedBy,
  }) => _remote.approve(clientId: clientId, companyId: companyId, returnNo: returnNo, returnDate: returnDate, approvedBy: approvedBy);

  @override
  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String returnNo,
  }) => _remote.getPostedVouchers(clientId: clientId, companyId: companyId, returnNo: returnNo);

  @override
  Future<List<Map<String, dynamic>>> getPostedVoucherLines({
    required String clientId,
    required String companyId,
    required String voucherNo,
    required String voucherDate,
  }) => _remote.getPostedVoucherLines(clientId: clientId, companyId: companyId, voucherNo: voucherNo, voucherDate: voucherDate);

  @override
  Future<void> cacheReturnLocally({
    required String effectiveReturnNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
  }) => _local?.cacheFromMaps(effectiveReturnNo, header, lines) ?? Future.value();
}
