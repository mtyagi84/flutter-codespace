import '../../data/models/category_level_model.dart';
import '../../data/models/item_category_model.dart';

abstract class ItemCategoriesRepository {
  Future<List<CategoryLevelModel>>  getLevels({required String clientId, required String companyId});
  Future<void>                      saveLevel(Map<String, dynamic> payload);
  Future<void>                      deleteLevel(String id);

  Future<List<ItemCategoryModel>>   getCategories({required String clientId, required String companyId});
  Future<void>                      saveCategory(Map<String, dynamic> payload);
  Future<void>                      softDeleteCategory({required String id, required String userId});
  Future<bool>                      hasChildren(String categoryId);
}
