import 'dart:async';
import '../../../../core/database/datasources/generic_lookup_local_ds.dart';
import '../../domain/repositories/item_categories_repository.dart';
import '../datasources/item_categories_remote_ds.dart';
import '../models/category_level_model.dart';
import '../models/item_category_model.dart';
import '../models/product_flag_type_model.dart';

class ItemCategoriesRepositoryImpl implements ItemCategoriesRepository {
  final ItemCategoriesRemoteDs _remote;
  final GenericLookupLocalDs?  _lookupLocal; // null on Flutter Web (no Drift)
  final bool                   _isOffline;
  final String                 _clientId;
  final String                 _companyId;

  ItemCategoriesRepositoryImpl(
    this._remote,
    this._lookupLocal,
    this._isOffline,
    this._clientId,
    this._companyId,
  );

  // Small helper for the reference-data getters below: try the cache first
  // when offline, otherwise fetch remote and cache for next time.
  Future<List<Map<String, dynamic>>> _cachedLookup({
    required String cacheKey,
    required Future<List<Map<String, dynamic>>> Function() fetchRemote,
  }) async {
    if (_isOffline && _lookupLocal != null) {
      return _lookupLocal.getLookups(cacheKey: cacheKey, clientId: _clientId, companyId: _companyId);
    }
    final rows = await fetchRemote();
    if (_lookupLocal != null) {
      unawaited(_lookupLocal.upsertLookups(
        cacheKey: cacheKey,
        rows: rows,
        idOf: (r) => r['id'] as String,
        clientId: _clientId,
        companyId: _companyId,
      ));
    }
    return rows;
  }

  @override
  Future<List<CategoryLevelModel>> getLevels({required String clientId, required String companyId}) async {
    final rows = await _cachedLookup(
      cacheKey: 'CATEGORY_LEVELS',
      fetchRemote: () async {
        final models = await _remote.getLevels(clientId: clientId, companyId: companyId);
        return models.map((m) => m.toJson()).toList();
      },
    );
    return rows.map((r) => CategoryLevelModel.fromJson(r)).toList();
  }

  @override Future<void> saveLevel(Map<String, dynamic> payload) => _remote.saveLevel(payload);
  @override Future<void> deleteLevel(String id) => _remote.deleteLevel(id);

  @override
  Future<List<ProductFlagTypeModel>> getFlagTypes({required String clientId, required String companyId}) async {
    final rows = await _cachedLookup(
      cacheKey: 'PRODUCT_FLAG_TYPES',
      fetchRemote: () async {
        final models = await _remote.getFlagTypes(clientId: clientId, companyId: companyId);
        return models.map((m) => m.toJson()).toList();
      },
    );
    return rows.map((r) => ProductFlagTypeModel.fromJson(r)).toList();
  }

  @override Future<void> saveFlagType(Map<String, dynamic> payload) => _remote.saveFlagType(payload);
  @override Future<void> deleteFlagType(String id) => _remote.deleteFlagType(id);

  @override Future<void> loadDefaultFlags({required String clientId, required String companyId}) =>
      _remote.loadDefaultFlags(clientId: clientId, companyId: companyId);

  @override
  Future<List<ItemCategoryModel>> getCategories({required String clientId, required String companyId}) async {
    final rows = await _cachedLookup(
      cacheKey: 'ITEM_CATEGORIES',
      fetchRemote: () async {
        final models = await _remote.getCategories(clientId: clientId, companyId: companyId);
        return models.map((m) => m.toJson()).toList();
      },
    );
    return rows.map((r) => ItemCategoryModel.fromJson(r)).toList();
  }

  @override Future<void> saveCategory(Map<String, dynamic> payload) => _remote.saveCategory(payload);

  @override Future<void> softDeleteCategory({required String id, required String userId}) =>
      _remote.softDeleteCategory(id: id, userId: userId);

  @override Future<void> cascadeFlagsToChildren({required List<String> childIds, required Map<String, dynamic> flags, required String userId}) =>
      _remote.cascadeFlagsToChildren(childIds: childIds, flags: flags, userId: userId);

  @override Future<bool> hasChildren(String categoryId) => _remote.hasChildren(categoryId);
}
