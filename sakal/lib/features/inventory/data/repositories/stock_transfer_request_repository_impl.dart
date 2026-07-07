import '../../domain/repositories/stock_transfer_request_repository.dart';
import '../datasources/stock_transfer_request_remote_ds.dart';

class StockTransferRequestRepositoryImpl implements StockTransferRequestRepository {
  final StockTransferRequestRemoteDs _remote;

  StockTransferRequestRepositoryImpl(this._remote);

  @override
  Future<List<Map<String, dynamic>>> listRequests({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) => _remote.listRequests(
        clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset,
      );

  @override
  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String requestNo,
    String? requestDate,
  }) => _remote.getHeader(clientId: clientId, companyId: companyId, requestNo: requestNo, requestDate: requestDate);

  @override
  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String requestNo,
    required String requestDate,
  }) => _remote.getLines(clientId: clientId, companyId: companyId, requestNo: requestNo, requestDate: requestDate);

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
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required String userId,
  }) => _remote.save(header: header, lines: lines, userId: userId);

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
