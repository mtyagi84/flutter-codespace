import '../../domain/repositories/opening_balance_repository.dart';
import '../datasources/opening_balance_remote_ds.dart';

class OpeningBalanceRepositoryImpl implements OpeningBalanceRepository {
  final OpeningBalanceRemoteDs _remote;

  OpeningBalanceRepositoryImpl(this._remote);

  @override
  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String fyId,
    String? locationGroupId,
  }) =>
      _remote.getLines(
        clientId: clientId, companyId: companyId, fyId: fyId, locationGroupId: locationGroupId,
      );

  @override
  Future<void> saveLines({
    required String clientId,
    required String companyId,
    required String fyId,
    String? locationGroupId,
    required List<Map<String, dynamic>> lines,
    required String userId,
  }) =>
      _remote.saveLines(
        clientId: clientId, companyId: companyId, fyId: fyId, locationGroupId: locationGroupId,
        lines: lines, userId: userId,
      );
}
