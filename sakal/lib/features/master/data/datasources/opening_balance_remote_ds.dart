import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';

class OpeningBalanceRemoteDs {
  final Dio _dio = DioClient.instance;

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String fyId,
    String? locationGroupId,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'fy_id':      'eq.$fyId',
      'is_deleted': 'eq.false',
      'select':     'id,account_id,fy_id,location_group_id,base_amount,local_amount,'
                    'party_amount,party_currency,ob_type,inv_bill_no,inv_bill_date,'
                    'rim_accounts!account_id(account_code,account_name,account_nature)',
      'order':      'created_at.asc',
    };
    params['location_group_id'] = locationGroupId != null ? 'eq.$locationGroupId' : 'is.null';
    final res = await _dio.get('/rid_opening_balance_lines', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<void> saveLines({
    required String clientId,
    required String companyId,
    required String fyId,
    String? locationGroupId,
    required List<Map<String, dynamic>> lines,
    required String userId,
  }) async {
    final deleteParams = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'fy_id':      'eq.$fyId',
    };
    deleteParams['location_group_id'] = locationGroupId != null ? 'eq.$locationGroupId' : 'is.null';
    await _dio.delete('/rid_opening_balance_lines', queryParameters: deleteParams);

    if (lines.isEmpty) return;

    final payload = lines.map((l) => {
          'client_id':          clientId,
          'company_id':         companyId,
          'account_id':         l['account_id'],
          'fy_id':               fyId,
          'location_group_id':   locationGroupId,
          'base_amount':         l['base_amount'],
          'local_amount':        l['local_amount'],
          'party_amount':        l['party_amount'],
          'party_currency':      l['party_currency'],
          'ob_type':             l['ob_type'],
          'inv_bill_no':         l['inv_bill_no'],
          'inv_bill_date':       l['inv_bill_date'],
          'created_by':          userId,
          'updated_by':          userId,
        }).toList();
    await _dio.post('/rid_opening_balance_lines', data: payload);
  }
}
