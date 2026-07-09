import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';

class StockCountRemoteDs {
  final Dio _dio = DioClient.instance;

  static const _headerSelect = '*,'
      'location:ric_locations!location_id(location_name)';

  Future<List<Map<String, dynamic>>> listStockCounts({
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
      'order':      'count_date.desc,count_no.desc',
      'limit':      '$limit',
      'offset':     '$offset',
    };
    if (status != null && status.isNotEmpty) params['status'] = 'eq.$status';
    if (search != null && search.isNotEmpty) params['count_no'] = 'ilike.*$search*';
    final res = await _dio.get('/rih_stock_count_headers', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String countNo,
    String? countDate,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'count_no':   'eq.$countNo',
      'is_deleted': 'eq.false',
      'select':     _headerSelect,
      'order':      'count_date.desc',
      'limit':      '1',
    };
    if (countDate != null && countDate.isNotEmpty) params['count_date'] = 'eq.$countDate';
    final res = await _dio.get('/rih_stock_count_headers', queryParameters: params);
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String countNo,
    required String countDate,
  }) async {
    final res = await _dio.get('/rid_stock_count_lines', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'count_no':   'eq.$countNo',
      'count_date': 'eq.$countDate',
      'is_deleted': 'eq.false',
      'select':     'serial_no,product_id,uom_id,uom_conversion_factor,'
          'is_counted,counted_qty_pack,counted_qty_loose,counted_base_qty,barcode,remarks,'
          'product:rim_products!product_id(product_code,product_name,tracking_type,barcode,part_number),'
          'uom:rim_common_masters!uom_id(description)',
      'order':      'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getLineBatches({
    required String clientId,
    required String companyId,
    required String countNo,
    required String countDate,
    required int    lineSerial,
  }) async {
    final res = await _dio.get('/rid_transaction_line_batches', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'source_doc_type': 'eq.STOCK_COUNT', 'source_doc_no': 'eq.$countNo', 'source_doc_date': 'eq.$countDate',
      'line_serial': 'eq.$lineSerial',
      'select': 'batch_no,expiry_date,manufacturing_date,qty_pack,qty_loose,base_qty',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getLineSerials({
    required String clientId,
    required String companyId,
    required String countNo,
    required String countDate,
    required int    lineSerial,
  }) async {
    final res = await _dio.get('/rid_transaction_line_serials', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'source_doc_type': 'eq.STOCK_COUNT', 'source_doc_no': 'eq.$countNo', 'source_doc_date': 'eq.$countDate',
      'line_serial': 'eq.$lineSerial',
      'select': 'serial_no',
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

  Future<List<Map<String, dynamic>>> getEligibleProducts({
    required String clientId,
    required String companyId,
    String? categoryId,
    String? nature,
  }) async {
    final res = await _dio.post('/rpc/fn_stock_count_eligible_products', data: {
      'p_client_id':   clientId,
      'p_company_id':  companyId,
      'p_category_id': categoryId,
      'p_nature':      nature,
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required String userId,
  }) async {
    final res = await _dio.post('/rpc/fn_save_stock_count', data: {
      'p_header':  header,
      'p_lines':   lines,
      'p_batches': batches,
      'p_serials': serials,
      'p_user_id': userId,
    });
    return res.data as String;
  }

  Future<void> submit({
    required String clientId,
    required String companyId,
    required String countNo,
    required String countDate,
    required String userId,
  }) async {
    await _dio.post('/rpc/fn_submit_stock_count', data: {
      'p_client_id':  clientId,
      'p_company_id': companyId,
      'p_count_no':   countNo,
      'p_count_date': countDate,
      'p_user_id':    userId,
    });
  }
}
