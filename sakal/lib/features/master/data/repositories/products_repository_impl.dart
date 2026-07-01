import '../../domain/repositories/products_repository.dart';
import '../datasources/products_local_ds.dart';
import '../datasources/products_remote_ds.dart';
import '../models/common_master_model.dart';
import '../models/item_category_model.dart';
import '../models/product_flag_type_model.dart';
import '../models/product_media_model.dart';
import '../models/product_model.dart';
import '../models/product_uom_model.dart';
import '../models/tax_group_model.dart';

class ProductsRepositoryImpl implements ProductsRepository {
  final ProductsRemoteDs  _remote;
  final ProductsLocalDs?  _local;       // null on web (no SQLite WASM)
  final bool              _offlineMode;

  ProductsRepositoryImpl({
    required ProductsRemoteDs  remote,
    required ProductsLocalDs?  local,
    required bool              offlineMode,
  })  : _remote      = remote,
        _local       = local,
        _offlineMode = offlineMode;

  @override
  Future<List<ProductModel>> getProducts({
    required String clientId,
    required String companyId,
    String? search,
    String? nature,
    bool?   isActive,
    int     limit  = 50,
    int     offset = 0,
  }) async {
    if (_offlineMode) {
      return _local!.getProducts(
        clientId:  clientId,
        companyId: companyId,
        search:    search,
        isActive:  isActive,
        limit:     limit,
        offset:    offset,
      );
    }
    final products = await _remote.getProducts(
      clientId:  clientId,
      companyId: companyId,
      search:    search,
      nature:    nature,
      isActive:  isActive,
      limit:     limit,
      offset:    offset,
    );
    // Cache first-page, no-search, no-filter results for offline
    if (offset == 0 && search == null && nature == null && isActive == null) {
      try { await _local?.upsertProducts(products); } catch (_) {}
    }
    return products;
  }

  @override
  Future<ProductModel?> getProduct(String id) async {
    if (_offlineMode) return _local?.getProduct(id);
    return _remote.getProduct(id);
  }

  @override
  Future<void> saveProduct(Map<String, dynamic> payload, {bool isNew = false}) =>
      _remote.saveProduct(payload, isNew: isNew);

  @override
  Future<String> generateProductCode({
    required String clientId,
    required String companyId,
  }) =>
      _remote.generateProductCode(clientId: clientId, companyId: companyId);

  @override
  Future<List<ProductUomModel>> getProductUoms(String productId) =>
      _remote.getProductUoms(productId);

  @override
  Future<void> saveProductUom(Map<String, dynamic> payload) =>
      _remote.saveProductUom(payload);

  @override
  Future<void> deleteProductUom(String id) => _remote.deleteProductUom(id);

  @override
  Future<List<ProductMediaModel>> getProductMedia(String productId) =>
      _remote.getProductMedia(productId);

  @override
  Future<void> saveProductMedia(Map<String, dynamic> payload) =>
      _remote.saveProductMedia(payload);

  @override
  Future<void> deleteProductMedia(String id) => _remote.deleteProductMedia(id);

  @override
  Future<List<ProductFlagTypeModel>> getFlagTypes({
    required String clientId,
    required String companyId,
  }) =>
      _remote.getFlagTypes(clientId: clientId, companyId: companyId);

  @override
  Future<Map<String, List<CommonMasterModel>>> loadMasterSets({
    required String clientId,
    required String companyId,
  }) =>
      _remote.loadMasterSets(clientId: clientId, companyId: companyId);

  @override
  Future<List<ItemCategoryModel>> getCategories({
    required String clientId,
    required String companyId,
  }) =>
      _remote.getCategories(clientId: clientId, companyId: companyId);

  @override
  Future<List<TaxGroupModel>> getTaxGroups({
    required String clientId,
    required String companyId,
  }) =>
      _remote.getTaxGroups(clientId: clientId, companyId: companyId);

  @override
  Future<List<Map<String, dynamic>>> getCurrencies(String clientId) =>
      _remote.getCurrencies(clientId);
}
