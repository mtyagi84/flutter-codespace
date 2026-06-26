import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';
import '../models/category_level_model.dart';
import '../models/item_category_model.dart';
import '../models/product_flag_type_model.dart';

class ItemCategoriesRemoteDs {
  final Dio _dio = DioClient.instance;

  // ── Category Levels ────────────────────────────────────────────────────────

  Future<List<CategoryLevelModel>> getLevels({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_category_levels', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_active':  'eq.true',
      'order':      'level_no.asc',
    });
    return (res.data as List)
        .map((e) => CategoryLevelModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveLevel(Map<String, dynamic> payload) async {
    final id = payload['id'] as String?;
    if (id == null) {
      await _dio.post('/rim_category_levels', data: payload);
    } else {
      await _dio.patch('/rim_category_levels',
          queryParameters: {'id': 'eq.$id'}, data: payload);
    }
  }

  Future<void> deleteLevel(String id) async {
    await _dio.delete('/rim_category_levels',
        queryParameters: {'id': 'eq.$id'});
  }

  // ── Product Flag Types ─────────────────────────────────────────────────────

  Future<List<ProductFlagTypeModel>> getFlagTypes({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_product_flag_types', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'order':      'sort_order.asc,flag_label.asc',
    });
    return (res.data as List)
        .map((e) => ProductFlagTypeModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveFlagType(Map<String, dynamic> payload) async {
    final id = payload['id'] as String?;
    if (id == null) {
      await _dio.post('/rim_product_flag_types', data: payload);
    } else {
      await _dio.patch('/rim_product_flag_types',
          queryParameters: {'id': 'eq.$id'}, data: payload);
    }
  }

  Future<void> deleteFlagType(String id) async {
    await _dio.delete('/rim_product_flag_types',
        queryParameters: {'id': 'eq.$id'});
  }

  Future<void> loadDefaultFlags({
    required String clientId,
    required String companyId,
  }) async {
    for (final d in ProductFlagTypeModel.defaults(
        clientId: clientId, companyId: companyId)) {
      try {
        await _dio.post('/rim_product_flag_types', data: d);
      } catch (_) {
        // Skip duplicates (unique constraint on flag_key)
      }
    }
  }

  // ── Item Categories ────────────────────────────────────────────────────────

  Future<List<ItemCategoryModel>> getCategories({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_item_categories', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'order':      'level_no.asc,sort_order.asc,category_name.asc',
      'limit':      '2000',
    });
    return (res.data as List)
        .map((e) => ItemCategoryModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveCategory(Map<String, dynamic> payload) async {
    final id = payload['id'] as String?;
    if (id == null) {
      await _dio.post('/rim_item_categories', data: payload);
    } else {
      await _dio.patch('/rim_item_categories',
          queryParameters: {'id': 'eq.$id'}, data: payload);
    }
  }

  Future<void> softDeleteCategory({
    required String id,
    required String userId,
  }) async {
    await _dio.patch('/rim_item_categories',
        queryParameters: {'id': 'eq.$id'},
        data: {
          'is_deleted': true,
          'updated_by': userId,
          'updated_at': DateTime.now().toIso8601String(),
        });
  }

  // Cascade updated flags to a list of descendant IDs (built client-side from tree)
  Future<void> cascadeFlagsToChildren({
    required List<String> childIds,
    required Map<String, dynamic> flags,
    required String userId,
  }) async {
    if (childIds.isEmpty) return;
    final inClause = childIds.join(',');
    await _dio.patch('/rim_item_categories',
        queryParameters: {'id': 'in.($inClause)'},
        data: {
          'flags':      flags,
          'updated_by': userId,
          'updated_at': DateTime.now().toIso8601String(),
        });
  }

  Future<bool> hasChildren(String categoryId) async {
    final res = await _dio.get('/rim_item_categories', queryParameters: {
      'parent_id':  'eq.$categoryId',
      'is_deleted': 'eq.false',
      'select':     'id',
      'limit':      '1',
    });
    return (res.data as List).isNotEmpty;
  }
}
