import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';
import '../models/common_master_model.dart';
import '../models/common_master_type_model.dart';

class CommonMastersRemoteDs {
  static const _typesTable   = '/rim_common_master_types';
  static const _mastersTable = '/rim_common_masters';

  static const _typesSelect   = 'id,type_key,type_name,is_active';
  static const _mastersSelect =
      'id,client_id,company_id,type_id,description,short_name,sort_order,is_active,is_deleted';

  Future<List<CommonMasterTypeModel>> getTypes() async {
    final res = await DioClient.instance.get(_typesTable, queryParameters: {
      'is_active': 'eq.true',
      'order':     'type_name.asc',
      'select':    _typesSelect,
    });
    return (res.data as List)
        .map((e) => CommonMasterTypeModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<CommonMasterModel>> getMasters({
    required String clientId,
    required String companyId,
    required String typeId,
    String? search,
    int limit  = 50,
    int offset = 0,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'type_id':    'eq.$typeId',
      'is_deleted': 'eq.false',
      'select':     _mastersSelect,
      'order':      'sort_order.asc,description.asc',
      'limit':      '$limit',
      'offset':     '$offset',
    };
    if (search != null && search.isNotEmpty) {
      params['description'] = 'ilike.*$search*';
    }
    final res = await DioClient.instance.get(_mastersTable, queryParameters: params);
    return (res.data as List)
        .map((e) => CommonMasterModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<CommonMasterModel> saveMaster(Map<String, dynamic> payload) async {
    final res = await DioClient.instance.post(
      _mastersTable,
      data: payload,
      queryParameters: {
        'on_conflict': 'client_id,company_id,type_id,description',
      },
      options: Options(headers: {
        'Prefer': 'resolution=merge-duplicates,return=representation',
      }),
    );
    final list = res.data as List;
    return CommonMasterModel.fromJson(list.first as Map<String, dynamic>);
  }

  Future<void> softDelete({
    required String id,
    required String userId,
  }) async {
    await DioClient.instance.patch(
      _mastersTable,
      data: {
        'is_deleted': true,
        'is_active':  false,
        'updated_by': userId,
        'updated_at': DateTime.now().toIso8601String(),
      },
      queryParameters: {'id': 'eq.$id'},
    );
  }
}
