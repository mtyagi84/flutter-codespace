import 'package:dio/dio.dart';
import '../../../../core/config/master_type_keys.dart';
import '../../../../core/network/dio_client.dart';
import '../models/common_master_model.dart';
import '../models/item_category_model.dart';
import '../models/product_flag_type_model.dart';
import '../models/product_media_model.dart';
import '../models/product_model.dart';
import '../models/product_uom_model.dart';
import '../models/tax_group_model.dart';

class ProductsRemoteDs {
  final Dio _dio = DioClient.instance;

  // ── Product list ───────────────────────────────────────────────────────────

  Future<List<ProductModel>> getProducts({
    required String clientId,
    required String companyId,
    String? search,
    String? nature,
    bool?   isActive,
    int     limit  = 50,
    int     offset = 0,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'select':     'id,product_code,product_name,product_nature,base_uom_id,is_active,'
                    'category:rim_item_categories!category_id(category_name),'
                    'base_uom:rim_common_masters!base_uom_id(description)',
      'order':      'product_code.asc',
      'limit':      '$limit',
      'offset':     '$offset',
    };
    if (search != null && search.isNotEmpty) {
      params['or'] = '(product_code.ilike.*$search*,product_name.ilike.*$search*)';
    }
    if (nature != null)   params['product_nature'] = 'eq.$nature';
    if (isActive != null) params['is_active']      = 'eq.$isActive';

    final res = await _dio.get('/rim_products', queryParameters: params);
    return (res.data as List)
        .map((e) => ProductModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ── Single product (for entry form) ────────────────────────────────────────

  Future<ProductModel?> getProduct(String id) async {
    final res = await _dio.get('/rim_products', queryParameters: {
      'id':         'eq.$id',
      'is_deleted': 'eq.false',
      'select':     '*',
      'limit':      '1',
    });
    final list = res.data as List;
    if (list.isEmpty) return null;
    return ProductModel.fromJson(list.first as Map<String, dynamic>);
  }

  // ── Save (INSERT or UPDATE) ─────────────────────────────────────────────────
  // isNew=true  → POST (client provides UUID in payload; DB uses it)
  // isNew=false → PATCH ?id=eq.<id>

  Future<void> saveProduct(Map<String, dynamic> payload, {bool isNew = false}) async {
    if (isNew) {
      await _dio.post('/rim_products', data: payload);
    } else {
      final id   = payload['id'] as String;
      final body = Map<String, dynamic>.from(payload)..remove('id');
      await _dio.patch('/rim_products',
          queryParameters: {'id': 'eq.$id'}, data: body,
          options: Options(headers: {'Prefer': 'return=minimal'}));
    }
  }

  // ── Product code auto-generate ──────────────────────────────────────────────

  Future<String> generateProductCode({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_products', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'select':     'id',
    });
    final count = (res.data as List).length + 1;
    return 'PRD-${count.toString().padLeft(5, '0')}';
  }

  // ── UOM levels ─────────────────────────────────────────────────────────────

  Future<List<ProductUomModel>> getProductUoms(String productId) async {
    final res = await _dio.get('/rim_product_uom', queryParameters: {
      'product_id': 'eq.$productId',
      'select':     'id,client_id,company_id,product_id,uom_id,conversion_factor,'
                    'barcode,is_base_uom,is_purchase_uom,is_sales_uom,sort_order,'
                    'uom_name:rim_common_masters!uom_id(description)',
      'order':      'is_base_uom.desc,sort_order.asc',
    });
    return (res.data as List)
        .map((e) => ProductUomModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveProductUom(Map<String, dynamic> payload) async {
    final id = payload['id'] as String?;
    if (id == null) {
      await _dio.post('/rim_product_uom', data: payload);
    } else {
      final body = Map<String, dynamic>.from(payload)..remove('id');
      await _dio.patch('/rim_product_uom',
          queryParameters: {'id': 'eq.$id'}, data: body,
          options: Options(headers: {'Prefer': 'return=minimal'}));
    }
  }

  Future<void> deleteProductUom(String id) async {
    await _dio.delete('/rim_product_uom', queryParameters: {'id': 'eq.$id'});
  }

  // ── Media ──────────────────────────────────────────────────────────────────

  Future<List<ProductMediaModel>> getProductMedia(String productId) async {
    final res = await _dio.get('/rim_product_media', queryParameters: {
      'product_id': 'eq.$productId',
      'select':     '*',
      'order':      'is_primary.desc,sort_order.asc',
    });
    return (res.data as List)
        .map((e) => ProductMediaModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveProductMedia(Map<String, dynamic> payload) async {
    await _dio.post('/rim_product_media', data: payload);
  }

  Future<void> deleteProductMedia(String id) async {
    await _dio.delete('/rim_product_media', queryParameters: {'id': 'eq.$id'});
  }

  // ── Reference data (loaded in parallel for entry form) ────────────────────

  /// Loads common masters for BRAND, UNIT, ITEM_SIZE, COLOR in 2 API calls.
  Future<Map<String, List<CommonMasterModel>>> loadMasterSets({
    required String clientId,
    required String companyId,
  }) async {
    const typeKeys = [
      MasterTypeKey.brand,
      MasterTypeKey.unit,
      MasterTypeKey.itemSize,
      MasterTypeKey.color,
    ];

    // Step 1: resolve type_key → type_id
    final typeRes = await _dio.get('/rim_common_master_types', queryParameters: {
      'type_key': 'in.(${typeKeys.join(',')})',
      'select':   'id,type_key',
      'is_active':'eq.true',
    });
    final typeList = typeRes.data as List;
    if (typeList.isEmpty) return {for (final k in typeKeys) k: []};

    final typeIdToKey = <String, String>{};
    final typeIds     = <String>[];
    for (final t in typeList) {
      final m = t as Map<String, dynamic>;
      typeIdToKey[m['id'] as String] = m['type_key'] as String;
      typeIds.add(m['id'] as String);
    }

    // Step 2: load all masters for those type IDs in one call
    final res = await _dio.get('/rim_common_masters', queryParameters: {
      'type_id':    'in.(${typeIds.join(',')})',
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'is_active':  'eq.true',
      'select':     'id,client_id,company_id,type_id,description,short_name,sort_order,is_active,is_deleted',
      'order':      'sort_order.asc,description.asc',
      'limit':      '500',
    });

    final result = <String, List<CommonMasterModel>>{
      for (final k in typeKeys) k: [],
    };
    for (final e in res.data as List) {
      final m   = CommonMasterModel.fromJson(e as Map<String, dynamic>);
      final key = typeIdToKey[m.typeId];
      if (key != null) result[key]!.add(m);
    }
    return result;
  }

  Future<List<ItemCategoryModel>> getCategories({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_item_categories', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'is_active':  'eq.true',
      'select':     'id,client_id,company_id,parent_id,level_no,category_name,sort_order',
      'order':      'level_no.asc,sort_order.asc,category_name.asc',
      'limit':      '2000',
    });
    return (res.data as List)
        .map((e) => ItemCategoryModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<TaxGroupModel>> getTaxGroups({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_tax_groups', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'is_active':  'eq.true',
      'select':     'id,group_code,group_name,applicable_on,client_id,company_id,'
                    'sort_order,is_active,is_deleted',
      'order':      'group_name.asc',
    });
    return (res.data as List)
        .map((e) => TaxGroupModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Map<String, dynamic>>> getCurrencies(String clientId) async {
    final res = await _dio.get('/rim_currencies', queryParameters: {
      'client_id': 'eq.$clientId',
      'is_active': 'eq.true',
      'select':    'id,currency_id,currency_name',
      'order':     'currency_name.asc',
    });
    return (res.data as List).cast<Map<String, dynamic>>();
  }

  Future<List<ProductFlagTypeModel>> getFlagTypes({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_product_flag_types', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_active':  'eq.true',
      'order':      'sort_order.asc',
    });
    return (res.data as List)
        .map((e) => ProductFlagTypeModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
