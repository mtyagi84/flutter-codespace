import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';

class OpeningStockRemoteDs {
  final Dio _dio = DioClient.instance;

  static const _headerSelect = '*,'
      'location:ric_locations!location_id(location_name)';

  Future<List<Map<String, dynamic>>> listOpeningStocks({
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
      'order':      'opening_date.desc,opening_no.desc',
      'limit':      '$limit',
      'offset':     '$offset',
    };
    if (status != null && status.isNotEmpty) params['status'] = 'eq.$status';
    if (search != null && search.isNotEmpty) params['opening_no'] = 'ilike.*$search*';
    final res = await _dio.get('/rih_opening_stock_headers', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String openingNo,
    String? openingDate,
  }) async {
    final params = <String, dynamic>{
      'client_id':   'eq.$clientId',
      'company_id':  'eq.$companyId',
      'opening_no':  'eq.$openingNo',
      'is_deleted':  'eq.false',
      'select':      _headerSelect,
      'order':       'opening_date.desc',
      'limit':       '1',
    };
    if (openingDate != null && openingDate.isNotEmpty) params['opening_date'] = 'eq.$openingDate';
    final res = await _dio.get('/rih_opening_stock_headers', queryParameters: params);
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String openingNo,
    required String openingDate,
  }) async {
    final res = await _dio.get('/rid_opening_stock_lines', queryParameters: {
      'client_id':    'eq.$clientId',
      'company_id':   'eq.$companyId',
      'opening_no':   'eq.$openingNo',
      'opening_date': 'eq.$openingDate',
      'is_deleted':   'eq.false',
      'select':       'line_no,product_id,uom_id,uom_conversion_factor,pack_qty,loose_qty,base_qty,'
          'batch_no,expiry_date,serial_no,unit_cost,unit_cost_specific,barcode,remarks,'
          'product:rim_products!product_id(product_code,product_name,tracking_type),'
          'uom:rim_common_masters!uom_id(description)',
      'order':        'line_no.asc',
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

  Future<Map<String, dynamic>?> getProductByCode({
    required String clientId,
    required String companyId,
    required String code,
    required bool tryPartNumber,
  }) async {
    final res = await _dio.get('/rim_product_uom', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'barcode':    'eq.$code',
      'select':     'uom_id,conversion_factor,'
          'product:rim_products!product_id(id,product_code,product_name,base_uom_id,tracking_type,is_active,is_deleted)',
      'limit':      '1',
    });
    final list = res.data as List;
    if (list.isNotEmpty) {
      final row = list.first as Map<String, dynamic>;
      final product = row['product'] as Map<String, dynamic>?;
      if (product != null && product['is_deleted'] != true && product['is_active'] != false) {
        return {
          ...product,
          'matched_uom_id': row['uom_id'],
          'matched_uom_conversion_factor': row['conversion_factor'],
        };
      }
    }

    if (!tryPartNumber) return null;

    final pRes = await _dio.get('/rim_products', queryParameters: {
      'client_id':   'eq.$clientId',
      'company_id':  'eq.$companyId',
      'part_number': 'eq.$code',
      'is_deleted':  'eq.false',
      'is_active':   'eq.true',
      'select':      'id,product_code,product_name,base_uom_id,tracking_type',
      'limit':       '1',
    });
    final pList = pRes.data as List;
    if (pList.isEmpty) return null;
    return pList.first as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>?> getCurrentStockAndCost({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) async {
    final res = await _dio.get('/rim_product_location', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'location_id': 'eq.$locationId', 'product_id': 'eq.$productId',
      'select': 'current_stock,cost_price',
      'limit': '1',
    });
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required String userId,
  }) async {
    final res = await _dio.post('/rpc/fn_save_opening_stock', data: {
      'p_header':  header,
      'p_lines':   lines,
      'p_user_id': userId,
    });
    return res.data as String;
  }

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String openingNo,
    required String openingDate,
    required String approvedBy,
  }) async {
    await _dio.post('/rpc/fn_approve_opening_stock', data: {
      'p_client_id':    clientId,
      'p_company_id':   companyId,
      'p_opening_no':   openingNo,
      'p_opening_date': openingDate,
      'p_approved_by':  approvedBy,
    });
  }
}
