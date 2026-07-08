import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';

class StockCountReviewRemoteDs {
  final Dio _dio = DioClient.instance;

  static const _headerSelect = '*,'
      'location:ric_locations!location_id(location_name),'
      'reason:rim_common_masters!reason_id(description)';

  Future<List<Map<String, dynamic>>> listReviews({
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
      'order':      'review_date.desc,review_no.desc',
      'limit':      '$limit',
      'offset':     '$offset',
    };
    if (status != null && status.isNotEmpty) params['status'] = 'eq.$status';
    if (search != null && search.isNotEmpty) params['review_no'] = 'ilike.*$search*';
    final res = await _dio.get('/rih_stock_count_review_headers', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String reviewNo,
    String? reviewDate,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'review_no':  'eq.$reviewNo',
      'is_deleted': 'eq.false',
      'select':     _headerSelect,
      'order':      'review_date.desc',
      'limit':      '1',
    };
    if (reviewDate != null && reviewDate.isNotEmpty) params['review_date'] = 'eq.$reviewDate';
    final res = await _dio.get('/rih_stock_count_review_headers', queryParameters: params);
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  Future<List<Map<String, dynamic>>> getSources({
    required String clientId,
    required String companyId,
    required String reviewNo,
    required String reviewDate,
  }) async {
    final res = await _dio.get('/rid_stock_count_review_sources', queryParameters: {
      'client_id':  'eq.$clientId', 'company_id': 'eq.$companyId',
      'review_no':  'eq.$reviewNo', 'review_date': 'eq.$reviewDate',
      'select':     'source_count_no,source_count_date',
      'order':      'source_count_no.asc',
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

  Future<List<Map<String, dynamic>>> getReasons({
    required String clientId,
    required String companyId,
  }) async {
    final typeRes = await _dio.get('/rim_common_master_types', queryParameters: {
      'type_key': 'eq.STOCK_ADJUSTMENT_REASON',
      'select':   'id',
      'limit':    '1',
    });
    final typeList = typeRes.data as List;
    if (typeList.isEmpty) return [];
    final typeId = (typeList.first as Map<String, dynamic>)['id'] as String;
    final res = await _dio.get('/rim_common_masters', queryParameters: {
      'type_id':    'eq.$typeId',
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'is_active':  'eq.true',
      'select':     'id,description',
      'order':      'sort_order.asc,description.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getSubmittedCounts({
    required String clientId,
    required String companyId,
    required String locationId,
    String? currentReviewNo,
  }) async {
    final params = <String, dynamic>{
      'client_id':   'eq.$clientId', 'company_id': 'eq.$companyId',
      'location_id': 'eq.$locationId', 'is_deleted': 'eq.false',
      'select':      'count_no,count_date,status,consolidated_into_review_no,remarks',
      'order':       'count_date.asc,count_no.asc',
    };
    if (currentReviewNo != null && currentReviewNo.isNotEmpty) {
      // SUBMITTED (still pickable) or already reserved by THIS review (so a
      // draft review can show its own already-checked sources).
      params['or'] = '(status.eq.SUBMITTED,consolidated_into_review_no.eq.$currentReviewNo)';
    } else {
      params['status'] = 'eq.SUBMITTED';
    }
    final res = await _dio.get('/rih_stock_count_headers', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getCountLines({
    required String clientId,
    required String companyId,
    required String countNo,
    required String countDate,
  }) async {
    final res = await _dio.get('/rid_stock_count_lines', queryParameters: {
      'client_id':  'eq.$clientId', 'company_id': 'eq.$companyId',
      'count_no':   'eq.$countNo', 'count_date': 'eq.$countDate',
      'is_deleted': 'eq.false', 'is_counted': 'eq.true',
      'select':     'serial_no,product_id,counted_qty_pack,counted_qty_loose,counted_base_qty,'
          'product:rim_products!product_id(product_code,product_name,tracking_type)',
      'order':      'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> sourceRefs,
    required String userId,
  }) async {
    final res = await _dio.post('/rpc/fn_save_stock_count_review', data: {
      'p_header':      header,
      'p_source_refs': sourceRefs,
      'p_user_id':     userId,
    });
    return res.data as String;
  }

  Future<List<Map<String, dynamic>>> computeVariance({
    required String clientId,
    required String companyId,
    required String reviewNo,
    required String reviewDate,
  }) async {
    final res = await _dio.post('/rpc/fn_compute_stock_count_variance', data: {
      'p_client_id':   clientId,
      'p_company_id':  companyId,
      'p_review_no':   reviewNo,
      'p_review_date': reviewDate,
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<String> approve({
    required String clientId,
    required String companyId,
    required String reviewNo,
    required String reviewDate,
    required String approvedBy,
  }) async {
    final res = await _dio.post('/rpc/fn_approve_stock_count_review', data: {
      'p_client_id':   clientId,
      'p_company_id':  companyId,
      'p_review_no':   reviewNo,
      'p_review_date': reviewDate,
      'p_approved_by': approvedBy,
    });
    return res.data as String;
  }
}
