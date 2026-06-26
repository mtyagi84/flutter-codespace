import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';
import '../models/category_level_model.dart';
import '../models/item_category_model.dart';

class ItemCategoriesRemoteDs {
  final Dio _dio = DioClient.instance;

  // ── Category Levels ────────────────────────────────────────────────────────

  Future<List<CategoryLevelModel>> getLevels({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get(
      '/rest/v1/rim_category_levels',
      queryParameters: {
        'client_id':  'eq.$clientId',
        'company_id': 'eq.$companyId',
        'is_active':  'eq.true',
        'order':      'level_no.asc',
      },
    );
    return (res.data as List)
        .map((e) => CategoryLevelModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveLevel(Map<String, dynamic> payload) async {
    final id = payload['id'] as String?;
    if (id == null) {
      await _dio.post('/rest/v1/rim_category_levels', data: payload);
    } else {
      await _dio.patch(
        '/rest/v1/rim_category_levels',
        queryParameters: {'id': 'eq.$id'},
        data: payload,
      );
    }
  }

  Future<void> deleteLevel(String id) async {
    await _dio.delete(
      '/rest/v1/rim_category_levels',
      queryParameters: {'id': 'eq.$id'},
    );
  }

  // ── Item Categories ────────────────────────────────────────────────────────

  Future<List<ItemCategoryModel>> getCategories({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get(
      '/rest/v1/rim_item_categories',
      queryParameters: {
        'client_id':  'eq.$clientId',
        'company_id': 'eq.$companyId',
        'is_deleted': 'eq.false',
        'order':      'level_no.asc,sort_order.asc,category_name.asc',
        'limit':      '1000',
      },
    );
    return (res.data as List)
        .map((e) => ItemCategoryModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveCategory(Map<String, dynamic> payload) async {
    final id = payload['id'] as String?;
    if (id == null) {
      await _dio.post('/rest/v1/rim_item_categories', data: payload);
    } else {
      await _dio.patch(
        '/rest/v1/rim_item_categories',
        queryParameters: {'id': 'eq.$id'},
        data: payload,
      );
    }
  }

  Future<void> softDeleteCategory({
    required String id,
    required String userId,
  }) async {
    await _dio.patch(
      '/rest/v1/rim_item_categories',
      queryParameters: {'id': 'eq.$id'},
      data: {
        'is_deleted': true,
        'updated_by': userId,
        'updated_at': DateTime.now().toIso8601String(),
      },
    );
  }

  Future<bool> hasChildren(String categoryId) async {
    final res = await _dio.get(
      '/rest/v1/rim_item_categories',
      queryParameters: {
        'parent_id':  'eq.$categoryId',
        'is_deleted': 'eq.false',
        'select':     'id',
        'limit':      '1',
      },
    );
    return (res.data as List).isNotEmpty;
  }
}
