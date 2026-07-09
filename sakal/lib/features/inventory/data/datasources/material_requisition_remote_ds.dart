import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';

class MaterialRequisitionRemoteDs {
  final Dio _dio = DioClient.instance;

  static const _headerSelect = '*,'
      'location:ric_locations!location_id(location_name)';

  Future<List<Map<String, dynamic>>> listRequisitions({
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
      'order':      'requisition_date.desc,requisition_no.desc',
      'limit':      '$limit',
      'offset':     '$offset',
    };
    if (status != null && status.isNotEmpty) params['status'] = 'eq.$status';
    if (search != null && search.isNotEmpty) params['requisition_no'] = 'ilike.*$search*';
    final res = await _dio.get('/rih_material_requisition_headers', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String requisitionNo,
    String? requisitionDate,
  }) async {
    final params = <String, dynamic>{
      'client_id':      'eq.$clientId',
      'company_id':     'eq.$companyId',
      'requisition_no': 'eq.$requisitionNo',
      'is_deleted':     'eq.false',
      'select':         _headerSelect,
      'order':          'requisition_date.desc',
      'limit':          '1',
    };
    if (requisitionDate != null && requisitionDate.isNotEmpty) params['requisition_date'] = 'eq.$requisitionDate';
    final res = await _dio.get('/rih_material_requisition_headers', queryParameters: params);
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String requisitionNo,
    required String requisitionDate,
  }) async {
    final res = await _dio.get('/rid_material_requisition_lines', queryParameters: {
      'client_id':        'eq.$clientId',
      'company_id':       'eq.$companyId',
      'requisition_no':   'eq.$requisitionNo',
      'requisition_date': 'eq.$requisitionDate',
      'is_deleted':       'eq.false',
      'select':           'serial_no,product_id,uom_id,uom_conversion_factor,qty_pack,qty_loose,base_qty,'
          'department_id,consumption_area_id,remarks,issued_qty,barcode,'
          'product:rim_products!product_id(product_code,product_name),'
          'uom:rim_common_masters!uom_id(description),'
          'department:rim_common_masters!department_id(description),'
          'area:rim_common_masters!consumption_area_id(description)',
      'order':            'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getLocationsForIssue({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/ric_locations', queryParameters: {
      'client_id':        'eq.$clientId',
      'company_id':       'eq.$companyId',
      'is_active':        'eq.true',
      'is_deleted':       'eq.false',
      'is_issue_allowed': 'eq.true',
      'select':           'id,location_name',
      'order':            'location_name.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getUsersForAutocomplete({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_users', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_active':  'eq.true',
      'is_deleted': 'eq.false',
      'select':     'full_name',
      'order':      'full_name.asc',
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

  Future<Map<String, dynamic>?> getProductByBarcode({
    required String clientId,
    required String companyId,
    required String barcode,
  }) async {
    final res = await _dio.get('/rim_product_uom', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'barcode':    'eq.$barcode',
      'select':     'uom_id,conversion_factor,'
          'product:rim_products!product_id(id,product_code,product_name,base_uom_id,tracking_type,is_active,is_deleted)',
      'limit':      '1',
    });
    final list = res.data as List;
    if (list.isEmpty) return null;
    final row = list.first as Map<String, dynamic>;
    final product = row['product'] as Map<String, dynamic>?;
    if (product == null || product['is_deleted'] == true || product['is_active'] == false) return null;
    return {
      ...product,
      'matched_uom_id': row['uom_id'],
      'matched_uom_conversion_factor': row['conversion_factor'],
    };
  }

  Future<List<Map<String, dynamic>>> getDepartments({
    required String clientId,
    required String companyId,
  }) async {
    final typeRes = await _dio.get('/rim_common_master_types', queryParameters: {
      'type_key': 'eq.DEPARTMENT', 'select': 'id', 'limit': '1',
    });
    final typeList = typeRes.data as List;
    if (typeList.isEmpty) return [];
    final typeId = (typeList.first as Map<String, dynamic>)['id'] as String;
    final res = await _dio.get('/rim_common_masters', queryParameters: {
      'type_id': 'eq.$typeId', 'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false', 'is_active': 'eq.true',
      'select': 'id,description', 'order': 'sort_order.asc,description.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Consumption areas linked under a specific department (via
  /// rim_department_consumption_areas) — the entry screen filters the area
  /// picker to only these once a department is chosen.
  Future<List<Map<String, dynamic>>> getConsumptionAreasForDepartment({
    required String clientId,
    required String companyId,
    required String departmentId,
  }) async {
    final res = await _dio.get('/rim_department_consumption_areas', queryParameters: {
      'client_id':     'eq.$clientId',
      'company_id':    'eq.$companyId',
      'department_id': 'eq.$departmentId',
      'is_deleted':    'eq.false',
      'select':        'consumption_area_id,area:rim_common_masters!consumption_area_id(id,description)',
    });
    return (res.data as List)
        .map((e) => (e as Map<String, dynamic>)['area'] as Map<String, dynamic>)
        .toList();
  }

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required String userId,
  }) async {
    final res = await _dio.post('/rpc/fn_save_material_requisition', data: {
      'p_header':  header,
      'p_lines':   lines,
      'p_user_id': userId,
    });
    return res.data as String;
  }

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String requisitionNo,
    required String requisitionDate,
    required String approvedBy,
  }) async {
    await _dio.post('/rpc/fn_approve_material_requisition', data: {
      'p_client_id':        clientId,
      'p_company_id':       companyId,
      'p_requisition_no':   requisitionNo,
      'p_requisition_date': requisitionDate,
      'p_approved_by':      approvedBy,
    });
  }
}
