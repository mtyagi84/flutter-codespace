import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';

class DepartmentConsumptionAreaRemoteDs {
  final Dio _dio = DioClient.instance;

  Future<String> _typeId(String typeKey) async {
    final res = await _dio.get('/rim_common_master_types', queryParameters: {
      'type_key': 'eq.$typeKey',
      'select':   'id',
      'limit':    '1',
    });
    final list = res.data as List;
    if (list.isEmpty) throw Exception('Common master type "$typeKey" is not seeded.');
    return (list.first as Map<String, dynamic>)['id'] as String;
  }

  Future<List<Map<String, dynamic>>> getDepartments({
    required String clientId,
    required String companyId,
  }) async {
    final typeId = await _typeId('DEPARTMENT');
    final res = await _dio.get('/rim_common_masters', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'type_id':    'eq.$typeId',
      'is_deleted': 'eq.false',
      'is_active':  'eq.true',
      'select':     'id,description',
      'order':      'sort_order.asc,description.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getConsumptionAreas({
    required String clientId,
    required String companyId,
  }) async {
    final typeId = await _typeId('CONSUMPTION_AREA');
    final res = await _dio.get('/rim_common_masters', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'type_id':    'eq.$typeId',
      'is_deleted': 'eq.false',
      'is_active':  'eq.true',
      'select':     'id,description',
      'order':      'sort_order.asc,description.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Every consumption-area id already linked to ANY department (globally
  /// unique — an area belongs to exactly one department) so the picker can
  /// exclude areas already claimed elsewhere.
  Future<Set<String>> getAllLinkedAreaIds({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_department_consumption_areas', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'select':     'consumption_area_id',
    });
    return (res.data as List).map((e) => (e as Map<String, dynamic>)['consumption_area_id'] as String).toSet();
  }

  Future<List<Map<String, dynamic>>> getLinksForDepartment({
    required String clientId,
    required String companyId,
    required String departmentId,
  }) async {
    final res = await _dio.get('/rim_department_consumption_areas', queryParameters: {
      'client_id':     'eq.$clientId',
      'company_id':    'eq.$companyId',
      'department_id': 'eq.$departmentId',
      'is_deleted':    'eq.false',
      'select':        'id,consumption_area_id,account_id,'
          'area:rim_common_masters!consumption_area_id(description),'
          'account:rim_accounts!account_id(account_code,account_name)',
      'order':         'created_at.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<void> saveLink({
    required Map<String, dynamic> payload,
  }) async {
    final id = payload['id'] as String?;
    if (id == null) {
      await _dio.post('/rim_department_consumption_areas', data: payload);
    } else {
      final data = Map<String, dynamic>.from(payload)..remove('id');
      await _dio.patch('/rim_department_consumption_areas', queryParameters: {'id': 'eq.$id'}, data: data);
    }
  }

  Future<void> deleteLink({required String id, required String userId}) async {
    await _dio.patch('/rim_department_consumption_areas', queryParameters: {'id': 'eq.$id'}, data: {
      'is_deleted': true,
      'is_active':  false,
      'updated_by': userId,
      'updated_at': DateTime.now().toIso8601String(),
    });
  }
}
