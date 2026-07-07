import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';

class StockTransferRequestRemoteDs {
  final Dio _dio = DioClient.instance;

  static const _headerSelect = '*,'
      'from_location:ric_locations!from_location_id(location_name),'
      'to_location:ric_locations!to_location_id(location_name)';

  Future<List<Map<String, dynamic>>> listRequests({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'select':     _headerSelect,
      'order':      'request_date.desc,request_no.desc',
      'limit':      '$limit',
      'offset':     '$offset',
    };
    if (status != null && status.isNotEmpty) params['status'] = 'eq.$status';
    if (search != null && search.isNotEmpty) params['request_no'] = 'ilike.*$search*';
    final res = await _dio.get('/rih_stock_transfer_requests', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String requestNo,
    String? requestDate,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'request_no': 'eq.$requestNo',
      'is_deleted': 'eq.false',
      'select':     _headerSelect,
      'order':      'request_date.desc',
      'limit':      '1',
    };
    if (requestDate != null && requestDate.isNotEmpty) params['request_date'] = 'eq.$requestDate';
    final res = await _dio.get('/rih_stock_transfer_requests', queryParameters: params);
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String requestNo,
    required String requestDate,
  }) async {
    final res = await _dio.get('/rid_stock_transfer_request_lines', queryParameters: {
      'client_id':   'eq.$clientId',
      'company_id':  'eq.$companyId',
      'request_no':  'eq.$requestNo',
      'request_date': 'eq.$requestDate',
      'is_deleted':  'eq.false',
      'select':      'serial_no,product_id,uom_id,uom_conversion_factor,qty_pack,qty_loose,base_qty,remarks,transferred_qty,'
          'product:rim_products!product_id(product_code,product_name),'
          'uom:rim_common_masters!uom_id(description)',
      'order':       'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getLocations({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/ric_locations', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_active':  'eq.true',
      'is_deleted': 'eq.false',
      'select':     'id,location_name',
      'order':      'location_name.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getProductsForPicker({
    required String clientId,
    required String companyId,
    String? search,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'is_active':  'eq.true',
      'select':     'id,product_code,product_name,base_uom_id,tracking_type,'
          'uom:rim_common_masters!base_uom_id(description)',
      'order':      'product_code.asc',
      'limit':      '500',
    };
    if (search != null && search.isNotEmpty) {
      params['or'] = '(product_code.ilike.*$search*,product_name.ilike.*$search*)';
    }
    final res = await _dio.get('/rim_products', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required String userId,
  }) async {
    final res = await _dio.post('/rpc/fn_save_stock_transfer_request', data: {
      'p_header':  header,
      'p_lines':   lines,
      'p_user_id': userId,
    });
    return res.data as String;
  }

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String requestNo,
    required String requestDate,
    required String approvedBy,
  }) async {
    await _dio.post('/rpc/fn_approve_stock_transfer_request', data: {
      'p_client_id':    clientId,
      'p_company_id':   companyId,
      'p_request_no':   requestNo,
      'p_request_date': requestDate,
      'p_approved_by':  approvedBy,
    });
  }
}
