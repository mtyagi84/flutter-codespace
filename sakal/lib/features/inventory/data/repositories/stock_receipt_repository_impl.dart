import '../../domain/repositories/stock_receipt_repository.dart';
import '../datasources/stock_receipt_remote_ds.dart';

class StockReceiptRepositoryImpl implements StockReceiptRepository {
  final StockReceiptRemoteDs _remote;

  StockReceiptRepositoryImpl(this._remote);

  @override
  Future<List<Map<String, dynamic>>> listReceipts({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) => _remote.listReceipts(
        clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset,
      );

  @override
  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String receiptNo,
    String? receiptDate,
  }) => _remote.getHeader(clientId: clientId, companyId: companyId, receiptNo: receiptNo, receiptDate: receiptDate);

  @override
  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String receiptNo,
    required String receiptDate,
  }) => _remote.getLines(clientId: clientId, companyId: companyId, receiptNo: receiptNo, receiptDate: receiptDate);

  @override
  Future<List<Map<String, dynamic>>> getReceivableTransfers({
    required String clientId,
    required String companyId,
    String? toLocationId,
  }) => _remote.getReceivableTransfers(clientId: clientId, companyId: companyId, toLocationId: toLocationId);

  @override
  Future<List<Map<String, dynamic>>> getTransferLines({
    required String clientId,
    required String companyId,
    required String transferNo,
    required String transferDate,
  }) => _remote.getTransferLines(clientId: clientId, companyId: companyId, transferNo: transferNo, transferDate: transferDate);

  @override
  Future<List<Map<String, dynamic>>> getDispatchedBatches({
    required String clientId,
    required String companyId,
    required String transferNo,
    required String transferDate,
    required int    lineSerial,
  }) => _remote.getDispatchedBatches(clientId: clientId, companyId: companyId, transferNo: transferNo, transferDate: transferDate, lineSerial: lineSerial);

  @override
  Future<List<Map<String, dynamic>>> getDispatchedSerials({
    required String clientId,
    required String companyId,
    required String transferNo,
    required String transferDate,
    required int    lineSerial,
  }) => _remote.getDispatchedSerials(clientId: clientId, companyId: companyId, transferNo: transferNo, transferDate: transferDate, lineSerial: lineSerial);

  @override
  Future<List<Map<String, dynamic>>> getReceiptLineBatches({
    required String clientId,
    required String companyId,
    required String receiptNo,
    required String receiptDate,
    required int    lineSerial,
  }) => _remote.getReceiptLineBatches(clientId: clientId, companyId: companyId, receiptNo: receiptNo, receiptDate: receiptDate, lineSerial: lineSerial);

  @override
  Future<List<Map<String, dynamic>>> getReceiptLineSerials({
    required String clientId,
    required String companyId,
    required String receiptNo,
    required String receiptDate,
    required int    lineSerial,
  }) => _remote.getReceiptLineSerials(clientId: clientId, companyId: companyId, receiptNo: receiptNo, receiptDate: receiptDate, lineSerial: lineSerial);

  @override
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required String userId,
  }) => _remote.save(header: header, lines: lines, batches: batches, serials: serials, userId: userId);

  @override
  Future<void> approve({
    required String clientId,
    required String companyId,
    required String receiptNo,
    required String receiptDate,
    required String approvedBy,
  }) => _remote.approve(
        clientId: clientId, companyId: companyId, receiptNo: receiptNo,
        receiptDate: receiptDate, approvedBy: approvedBy,
      );

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
}
