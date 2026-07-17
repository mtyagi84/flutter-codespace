import 'package:dio/dio.dart';
import '../network/dio_client.dart';

/// Bulk "fetch everything" reads for the Master-Data Sync facility
/// (see master_data_modules.dart / master_data_sync_service.dart).
///
/// Deliberately separate from every module's own picker-search remote
/// datasource (e.g. sales_invoice_remote_ds.dart's getProductsForPicker) —
/// those are search-driven and capped (limit: 500); a full-catalog sync
/// needs paginated "fetch everything" methods instead. Most other
/// master-data types (Locations, Currencies, Tax Groups, Common Masters,
/// Additional Charges, Users) already have complete, unfiltered fetches
/// via their existing providers/repositories — only Products, Product
/// UOM, Tax Group Members, and Tax Rates need a genuinely new bulk API
/// here (see the plan's "Reuse vs. new-fetch" section).
class MasterDataRemoteDs {
  final Dio _dio = DioClient.instance;

  static const int _pageSize = 500;

  Future<List<Map<String, dynamic>>> getAllProducts({
    required String clientId,
    required String companyId,
  }) async {
    final all = <Map<String, dynamic>>[];
    var offset = 0;
    while (true) {
      final res = await _dio.get('/rim_products', queryParameters: {
        'client_id': 'eq.$clientId',
        'company_id': 'eq.$companyId',
        'is_deleted': 'eq.false',
        'is_active': 'eq.true',
        'select': 'id,client_id,company_id,product_code,product_name,product_nature,barcode,part_number,'
            'short_name,description,category_id,brand_id,item_size_id,item_color_id,base_uom_id,'
            'standard_cost,average_cost,last_purchase_cost,allowed_cost_variance,cost_currency_id,'
            'sales_tax_group_id,purchase_tax_group_id,tracking_type,is_active,is_deleted',
        'order': 'product_code.asc',
        'limit': '$_pageSize',
        'offset': '$offset',
      });
      final page = List<Map<String, dynamic>>.from(res.data as List);
      all.addAll(page);
      if (page.length < _pageSize) break;
      offset += _pageSize;
    }
    return all;
  }

  /// Batched by product id (~200/call) to stay under practical PostgREST
  /// URL-length limits on the `in.()` filter.
  Future<List<Map<String, dynamic>>> getAllProductUoms(List<String> productIds) async {
    if (productIds.isEmpty) return [];
    final all = <Map<String, dynamic>>[];
    const chunkSize = 200;
    for (var i = 0; i < productIds.length; i += chunkSize) {
      final chunk = productIds.sublist(i, i + chunkSize > productIds.length ? productIds.length : i + chunkSize);
      final res = await _dio.get('/rim_product_uom', queryParameters: {
        'product_id': 'in.(${chunk.join(',')})',
        'select': 'product_id,uom_id,conversion_factor,is_base_uom,barcode,'
            'uom:rim_common_masters!uom_id(description)',
      });
      all.addAll(List<Map<String, dynamic>>.from(res.data as List));
    }
    return all;
  }

  Future<List<Map<String, dynamic>>> getAllTaxGroupMembers({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_tax_group_members', queryParameters: {
      'client_id': 'eq.$clientId',
      'company_id': 'eq.$companyId',
      'select': 'tax_group_id,tax_id',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getAllTaxRates({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_tax_rates', queryParameters: {
      'client_id': 'eq.$clientId',
      'company_id': 'eq.$companyId',
      'rate_label': 'eq.STANDARD',
      'is_active': 'eq.true',
      'select': 'tax_id,rate_label,rate,effective_from,effective_to,is_active',
      'order': 'effective_from.desc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }
}
