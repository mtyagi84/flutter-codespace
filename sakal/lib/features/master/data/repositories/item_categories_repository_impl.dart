import '../../domain/repositories/item_categories_repository.dart';
import '../datasources/item_categories_remote_ds.dart';
import '../models/category_level_model.dart';
import '../models/item_category_model.dart';

class ItemCategoriesRepositoryImpl implements ItemCategoriesRepository {
  final ItemCategoriesRemoteDs _remote;

  ItemCategoriesRepositoryImpl(this._remote);

  @override
  Future<List<CategoryLevelModel>> getLevels({
    required String clientId,
    required String companyId,
  }) =>
      _remote.getLevels(clientId: clientId, companyId: companyId);

  @override
  Future<void> saveLevel(Map<String, dynamic> payload) =>
      _remote.saveLevel(payload);

  @override
  Future<void> deleteLevel(String id) => _remote.deleteLevel(id);

  @override
  Future<List<ItemCategoryModel>> getCategories({
    required String clientId,
    required String companyId,
  }) =>
      _remote.getCategories(clientId: clientId, companyId: companyId);

  @override
  Future<void> saveCategory(Map<String, dynamic> payload) =>
      _remote.saveCategory(payload);

  @override
  Future<void> softDeleteCategory({
    required String id,
    required String userId,
  }) =>
      _remote.softDeleteCategory(id: id, userId: userId);

  @override
  Future<bool> hasChildren(String categoryId) =>
      _remote.hasChildren(categoryId);
}
