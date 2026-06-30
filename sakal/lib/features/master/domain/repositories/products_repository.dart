import '../../data/models/common_master_model.dart';
import '../../data/models/item_category_model.dart';
import '../../data/models/product_flag_type_model.dart';
import '../../data/models/product_media_model.dart';
import '../../data/models/product_model.dart';
import '../../data/models/product_uom_model.dart';
import '../../data/models/tax_group_model.dart';

abstract class ProductsRepository {
  Future<List<ProductModel>> getProducts({
    required String clientId,
    required String companyId,
    String? search,
    String? nature,
    bool?   isActive,
    int     limit,
    int     offset,
  });

  Future<ProductModel?> getProduct(String id);
  Future<void>          saveProduct(Map<String, dynamic> payload, {bool isNew});
  Future<String>        generateProductCode({required String clientId, required String companyId});

  Future<List<ProductUomModel>> getProductUoms(String productId);
  Future<void>                  saveProductUom(Map<String, dynamic> payload);
  Future<void>                  deleteProductUom(String id);

  Future<List<ProductMediaModel>> getProductMedia(String productId);
  Future<void>                    saveProductMedia(Map<String, dynamic> payload);
  Future<void>                    deleteProductMedia(String id);

  Future<List<ProductFlagTypeModel>> getFlagTypes({required String clientId, required String companyId});

  Future<Map<String, List<CommonMasterModel>>> loadMasterSets({required String clientId, required String companyId});
  Future<List<ItemCategoryModel>>              getCategories({required String clientId, required String companyId});
  Future<List<TaxGroupModel>>                  getTaxGroups({required String clientId, required String companyId});
  Future<List<Map<String, dynamic>>>           getCurrencies(String clientId);
}
