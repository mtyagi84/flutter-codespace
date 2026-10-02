import 'package:dio/dio.dart';
import '../../../core/network/dio_client.dart';

/// Which POS terminals a user may sign into — the per-terminal layer on top
/// of `ric_user_location_access` (store access is a prerequisite, checked
/// separately; this table only narrows further, same split
/// docs/pos/06_access_security.md §2 specifies). Mirrors
/// `UserLocationAccessHelper`'s own upsert-toggle shape exactly: unchecking a
/// terminal flips `is_active=false` rather than deleting the row, so the
/// history survives and re-checking it later is a plain UPDATE, never a
/// second INSERT that would violate the table's own UNIQUE constraint.
class PosTerminalAccessHelper {
  PosTerminalAccessHelper._();

  static Future<Set<String>> getForUser({
    required String clientId,
    required String companyId,
    required String userId,
  }) async {
    final res = await DioClient.instance.get('/ric_user_pos_terminal_access', queryParameters: {
      'client_id': 'eq.$clientId',
      'company_id': 'eq.$companyId',
      'user_id': 'eq.$userId',
      'is_active': 'eq.true',
      'is_deleted': 'eq.false',
      'select': 'terminal_id',
    });
    return Set<String>.from((res.data as List).map((r) => (r as Map<String, dynamic>)['terminal_id'] as String));
  }

  static Future<void> save({
    required String clientId,
    required String companyId,
    required String userId,
    required Set<String> selectedTerminalIds,
  }) async {
    final existingRes = await DioClient.instance.get('/ric_user_pos_terminal_access', queryParameters: {
      'client_id': 'eq.$clientId',
      'company_id': 'eq.$companyId',
      'user_id': 'eq.$userId',
      'is_deleted': 'eq.false',
      'select': 'terminal_id',
    });
    final existingIds = Set<String>.from(
        (existingRes.data as List).map((r) => (r as Map<String, dynamic>)['terminal_id'] as String));

    final union = {...existingIds, ...selectedTerminalIds};
    if (union.isEmpty) return;

    final rows = union
        .map((terminalId) => {
              'client_id': clientId,
              'company_id': companyId,
              'user_id': userId,
              'terminal_id': terminalId,
              'access_type': 'PERMANENT',
              'is_active': selectedTerminalIds.contains(terminalId),
            })
        .toList();

    await DioClient.instance.post(
      '/ric_user_pos_terminal_access',
      data: rows,
      queryParameters: {'on_conflict': 'client_id,company_id,user_id,terminal_id'},
      options: Options(headers: {'Prefer': 'resolution=merge-duplicates'}),
    );
  }
}
