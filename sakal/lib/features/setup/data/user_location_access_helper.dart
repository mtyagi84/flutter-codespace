import 'package:dio/dio.dart';
import '../../../core/network/dio_client.dart';

/// Shared by the standalone User Location Access screen and the
/// Add/Edit User dialog — both assign a user to multiple locations
/// with one marked as default.
class UserLocationAccessHelper {
  UserLocationAccessHelper._();

  static Future<Map<String, dynamic>> getForUser({
    required String clientId,
    required String companyId,
    required String userId,
  }) async {
    final res = await DioClient.instance.get('/ric_user_location_access', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'user_id':    'eq.$userId',
      'is_active':  'eq.true',
      'is_deleted': 'eq.false',
      'select':     'location_id,is_default',
    });
    final rows = List<Map<String, dynamic>>.from(res.data as List);
    return {
      'selected': rows.map((r) => r['location_id'] as String).toSet(),
      'default': rows
          .where((r) => r['is_default'] as bool? ?? false)
          .map((r) => r['location_id'] as String)
          .firstOrNull,
    };
  }

  /// Upserts one row per location the user has ever been assigned to
  /// (union of previously and currently selected), toggling is_active
  /// so unchecked locations stay as history rather than being deleted.
  /// Also keeps rim_users.default_location_id in sync since that column
  /// drives the JWT location claim at login.
  static Future<void> save({
    required String clientId,
    required String companyId,
    required String userId,
    required Set<String> selectedLocationIds,
    required String? defaultLocationId,
    required String updatedBy,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();

    final existingRes = await DioClient.instance.get('/ric_user_location_access', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'user_id':    'eq.$userId',
      'is_deleted': 'eq.false',
      'select':     'location_id',
    });
    final existingIds = Set<String>.from(
        (existingRes.data as List).map((r) => (r as Map<String, dynamic>)['location_id'] as String));

    final union = {...existingIds, ...selectedLocationIds};
    if (union.isNotEmpty) {
      final rows = union.map((locId) => {
            'client_id':  clientId,
            'company_id': companyId,
            'user_id':    userId,
            'location_id': locId,
            'is_active':  selectedLocationIds.contains(locId),
            'is_default': selectedLocationIds.contains(locId) && locId == defaultLocationId,
            'updated_at': now,
            'updated_by': updatedBy,
          }).toList();
      await DioClient.instance.post(
        '/ric_user_location_access',
        data: rows,
        queryParameters: {'on_conflict': 'user_id,location_id'},
        options: Options(headers: {'Prefer': 'resolution=merge-duplicates'}),
      );
    }

    await DioClient.instance.patch(
      '/rim_users',
      queryParameters: {'id': 'eq.$userId'},
      data: {'default_location_id': defaultLocationId, 'updated_at': now, 'updated_by': updatedBy},
      options: Options(headers: {'Prefer': 'return=minimal'}),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
