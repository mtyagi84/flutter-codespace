import '../../domain/repositories/stock_count_review_repository.dart';
import '../datasources/stock_count_review_remote_ds.dart';

/// Online-only — no Drift caching. See project docs: a live view of other
/// counters' SUBMITTED status and a live ledger-based system-qty
/// computation are both required for correctness; a stale local replica
/// would actively mislead the manager. Approve is a real posting action,
/// already online-only by existing convention.
class StockCountReviewRepositoryImpl implements StockCountReviewRepository {
  final StockCountReviewRemoteDs _remote;

  StockCountReviewRepositoryImpl(this._remote);

  @override
  Future<List<Map<String, dynamic>>> listReviews({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) => _remote.listReviews(clientId: clientId, companyId: companyId, search: search, status: status, limit: limit, offset: offset);

  @override
  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String reviewNo,
    String? reviewDate,
  }) => _remote.getHeader(clientId: clientId, companyId: companyId, reviewNo: reviewNo, reviewDate: reviewDate);

  @override
  Future<List<Map<String, dynamic>>> getSources({
    required String clientId,
    required String companyId,
    required String reviewNo,
    required String reviewDate,
  }) => _remote.getSources(clientId: clientId, companyId: companyId, reviewNo: reviewNo, reviewDate: reviewDate);

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
  Future<List<Map<String, dynamic>>> getSubmittedCounts({
    required String clientId,
    required String companyId,
    required String locationId,
    String? currentReviewNo,
  }) => _remote.getSubmittedCounts(clientId: clientId, companyId: companyId, locationId: locationId, currentReviewNo: currentReviewNo);

  @override
  Future<List<Map<String, dynamic>>> getCountLines({
    required String clientId,
    required String companyId,
    required String countNo,
    required String countDate,
  }) => _remote.getCountLines(clientId: clientId, companyId: companyId, countNo: countNo, countDate: countDate);

  @override
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> sourceRefs,
    required String userId,
  }) => _remote.save(header: header, sourceRefs: sourceRefs, userId: userId);

  @override
  Future<List<Map<String, dynamic>>> computeVariance({
    required String clientId,
    required String companyId,
    required String reviewNo,
    required String reviewDate,
  }) => _remote.computeVariance(clientId: clientId, companyId: companyId, reviewNo: reviewNo, reviewDate: reviewDate);

  @override
  Future<String> approve({
    required String clientId,
    required String companyId,
    required String reviewNo,
    required String reviewDate,
    required String approvedBy,
  }) => _remote.approve(clientId: clientId, companyId: companyId, reviewNo: reviewNo, reviewDate: reviewDate, approvedBy: approvedBy);
}
