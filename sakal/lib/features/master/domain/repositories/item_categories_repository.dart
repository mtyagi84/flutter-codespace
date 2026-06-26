import '../../data/models/category_level_model.dart';
import '../../data/models/item_category_model.dart';
import '../../data/models/product_flag_type_model.dart';

abstract class ItemCategoriesRepository {
  // Levels
  Future<List<CategoryLevelModel>> getLevels({required String clientId, required String companyId});
  Future<void> saveLevel(Map<String, dynamic> payload);
  Future<void> deleteLevel(String id);

  // Flag types
  Future<List<ProductFlagTypeModel>> getFlagTypes({required String clientId, required String companyId});
  Future<void> saveFlagType(Map<String, dynamic> payload);
  Future<void> deleteFlagType(String id);
  Future<void> loadDefaultFlags({required String clientId, required String companyId});

  // Categories
  Future<List<ItemCategoryModel>> getCategories({required String clientId, required String companyId});
  Future<void> saveCategory(Map<String, dynamic> payload);
  Future<void> softDeleteCategory({required String id, required String userId});
  Future<void> cascadeFlagsToChildren({required List<String> childIds, required Map<String, dynamic> flags, required String userId});
  Future<bool> hasChildren(String categoryId);
}
