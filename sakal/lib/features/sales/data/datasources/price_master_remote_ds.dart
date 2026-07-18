import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';

class PriceMasterRemoteDs {
  final Dio _dio = DioClient.instance;

  static const _headerSelect = '*,'
      'customer:rim_accounts!customer_id(account_code,account_name),'
      'location:ric_locations!location_id(location_name),'
      'currency:rim_currencies!price_currency_id(currency_id,currency_name)';

  /// List select embeds a nested PostgREST aggregate count of this batch's
  /// own lines (`rid_price_master_lines(count)`) so the list screen's Line
  /// Count column needs no per-row follow-up query — Sales Quotation has no
  /// equivalent column to mirror, this is PostgREST's documented
  /// to-many-count-embed feature used fresh here.
  static const _listSelect = '*,'
      'customer:rim_accounts!customer_id(account_code,account_name),'
      'location:ric_locations!location_id(location_name),'
      'currency:rim_currencies!price_currency_id(currency_id,currency_name),'
      'rid_price_master_lines(count)';

  Future<List<Map<String, dynamic>>> listBatches({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    String? priceType,
    String? locationId,
    int     limit  = 50,
    int     offset = 0,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'select':     _listSelect,
      'order':      'entry_date.desc,entry_no.desc',
      'limit':      '$limit',
      'offset':     '$offset',
    };
    if (status != null && status.isNotEmpty) params['status'] = 'eq.$status';
    if (priceType != null && priceType.isNotEmpty) params['price_type'] = 'eq.$priceType';
    if (locationId != null && locationId.isNotEmpty) params['location_id'] = 'eq.$locationId';
    if (search != null && search.isNotEmpty) params['entry_no'] = 'ilike.*$search*';
    final res = await _dio.get('/rih_price_master_headers', queryParameters: params);
    final rows = List<Map<String, dynamic>>.from(res.data as List);
    for (final r in rows) {
      final embed = r['rid_price_master_lines'];
      r['line_count'] = (embed is List && embed.isNotEmpty) ? (embed.first['count'] as num?)?.toInt() ?? 0 : 0;
    }
    return rows;
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String entryNo,
    String? entryDate,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'entry_no':   'eq.$entryNo',
      'is_deleted': 'eq.false',
      'select':     _headerSelect,
      'order':      'entry_date.desc',
      'limit':      '1',
    };
    if (entryDate != null && entryDate.isNotEmpty) params['entry_date'] = 'eq.$entryDate';
    final res = await _dio.get('/rih_price_master_headers', queryParameters: params);
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String entryNo,
    required String entryDate,
  }) async {
    final res = await _dio.get('/rid_price_master_lines', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'entry_no':   'eq.$entryNo',
      'entry_date': 'eq.$entryDate',
      'is_deleted': 'eq.false',
      'select':     'serial_no,product_id,uom_id,uom_conversion_factor,barcode,'
          'cost_price,margin_percent,selling_price,below_cost_reason_id,'
          'is_tax_inclusive,remarks,'
          'product:rim_products!product_id(product_code,product_name,cost_currency_id),'
          'uom:rim_common_masters!uom_id(description),'
          'below_cost_reason:rim_common_masters!below_cost_reason_id(description)',
      'order':      'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getProductsForPicker({
    required String clientId,
    required String companyId,
    String? search,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'is_active':  'eq.true',
      'select':     'id,product_code,product_name,base_uom_id,cost_currency_id,'
          'uom:rim_common_masters!base_uom_id(description)',
      'order':      'product_code.asc',
      'limit':      '500',
    };
    if (search != null && search.isNotEmpty) {
      params['or'] = '(product_code.ilike.*$search*,product_name.ilike.*$search*)';
    }
    final res = await _dio.get('/rim_products', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// A product's own pack sizes — scopes the per-line UOM dropdown to only
  /// the UOMs actually configured for the selected product (a Piece price
  /// and a Carton price are two separate lines, never a free UOM picklist).
  ///
  /// Real bug found live: rim_product_uom only holds ADDITIONAL pack sizes
  /// (Carton/Pallet) — picking a Base UOM on Product Master's "UOM &
  /// Tracking" section sets rim_products.base_uom_id but does NOT
  /// auto-create a matching rim_product_uom row (that needs a separate
  /// manual "+ Add UOM" action in a different section of the same screen).
  /// A product can legitimately have a correct base_uom_id and zero
  /// rim_product_uom rows — this returned an empty list for it, blocking
  /// price entry entirely even though the unit is perfectly well-defined.
  /// Falls back to the product's own base_uom_id when rim_product_uom is
  /// empty, in the exact same shape a real row would have, so the caller
  /// (the UOM dropdown builder) needs no change at all.
  Future<List<Map<String, dynamic>>> getProductUoms(String productId) async {
    final res = await _dio.get('/rim_product_uom', queryParameters: {
      'product_id': 'eq.$productId',
      'select':     'uom_id,conversion_factor,is_base_uom,'
          'uom:rim_common_masters!uom_id(description)',
      'order':      'is_base_uom.desc,sort_order.asc',
    });
    final rows = List<Map<String, dynamic>>.from(res.data as List);
    if (rows.isNotEmpty) return rows;

    final productRes = await _dio.get('/rim_products', queryParameters: {
      'id':     'eq.$productId',
      'select': 'base_uom_id,uom:rim_common_masters!base_uom_id(description)',
      'limit':  '1',
    });
    final productList = productRes.data as List;
    if (productList.isEmpty) return [];
    final product = productList.first as Map<String, dynamic>;
    final baseUomId = product['base_uom_id'] as String?;
    if (baseUomId == null) return [];
    return [
      {
        'uom_id': baseUomId,
        'conversion_factor': 1,
        'is_base_uom': true,
        'uom': product['uom'],
      },
    ];
  }

  /// Below-cost reason picker — same two-step common-masters lookup as
  /// Stock Adjustment's own getReasons() (stock_adjustment_remote_ds.dart),
  /// just swapping the type_key to the new 'PRICE_BELOW_COST_REASON'
  /// (migration 083).
  Future<List<Map<String, dynamic>>> getReasons({
    required String clientId,
    required String companyId,
  }) async {
    final typeRes = await _dio.get('/rim_common_master_types', queryParameters: {
      'type_key': 'eq.PRICE_BELOW_COST_REASON',
      'select':   'id',
      'limit':    '1',
    });
    final typeList = typeRes.data as List;
    if (typeList.isEmpty) return [];
    final typeId = (typeList.first as Map<String, dynamic>)['id'] as String;
    final res = await _dio.get('/rim_common_masters', queryParameters: {
      'type_id':    'eq.$typeId',
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'is_active':  'eq.true',
      'select':     'id,description',
      'order':      'sort_order.asc,description.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Barcode-first / part-number-fallback product lookup for the header
  /// scan field — mirrors OpeningStockRemoteDs.getProductByCode() exactly
  /// (barcode match via rim_product_uom, part number fallback via
  /// rim_products.part_number only if tryPartNumber), with the correct
  /// forward-slash paths (the file this was copied from was checked for the
  /// backslash typo the requirement doc warned about; it was not present in
  /// the current source, but the paths below are written correctly either
  /// way). Adds cost_currency_id to both result shapes — this screen's own
  /// three-way cost rule needs it, which Opening Stock's version has no
  /// reason to select.
  Future<Map<String, dynamic>?> getProductByCode({
    required String clientId,
    required String companyId,
    required String code,
    required bool tryPartNumber,
  }) async {
    final res = await _dio.get('/rim_product_uom', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'barcode':    'eq.$code',
      'select':     'uom_id,conversion_factor,'
          'uom:rim_common_masters!uom_id(description),'
          'product:rim_products!product_id(id,product_code,product_name,base_uom_id,'
          'cost_currency_id,is_active,is_deleted)',
      'limit':      '1',
    });
    final list = res.data as List;
    if (list.isNotEmpty) {
      final row = list.first as Map<String, dynamic>;
      final product = row['product'] as Map<String, dynamic>?;
      if (product != null && product['is_deleted'] != true && product['is_active'] != false) {
        final uom = row['uom'] as Map<String, dynamic>?;
        return {
          ...product,
          'matched_uom_id': row['uom_id'],
          'matched_uom_conversion_factor': row['conversion_factor'],
          'matched_uom_label': uom?['description'],
        };
      }
    }

    if (!tryPartNumber) return null;

    final pRes = await _dio.get('/rim_products', queryParameters: {
      'client_id':   'eq.$clientId',
      'company_id':  'eq.$companyId',
      'part_number': 'eq.$code',
      'is_deleted':  'eq.false',
      'is_active':   'eq.true',
      'select':      'id,product_code,product_name,base_uom_id,cost_currency_id,'
          'uom:rim_common_masters!base_uom_id(description)',
      'limit':       '1',
    });
    final pList = pRes.data as List;
    if (pList.isEmpty) return null;
    final product = pList.first as Map<String, dynamic>;
    final uom = product['uom'] as Map<String, dynamic>?;
    return {
      ...product,
      'matched_uom_label': uom?['description'],
    };
  }

  /// rim_product_location's current cost, at this Location — feeds the
  /// three-way Cost Price display rule (docs/screens/sales_price_master.md
  /// §4). Own version of OpeningStockRemoteDs.getCurrentStockAndCost(),
  /// widened to also select cost_price_specific (that shared method only
  /// needs current_stock/cost_price for its own screen) — kept as a
  /// separate method here rather than modifying the shared Opening Stock
  /// file.
  Future<Map<String, dynamic>?> getProductLocationCost({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) async {
    final res = await _dio.get('/rim_product_location', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'location_id': 'eq.$locationId', 'product_id': 'eq.$productId',
      'select': 'current_stock,cost_price,cost_price_specific',
      'limit': '1',
    });
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  /// Rate to Base, fetched via fn_get_exchange_rate — same SELLING-rate
  /// convention and same call shape as
  /// SalesQuotationRemoteDs.getExchangeRate(). Returns null (never throws)
  /// if no rate is configured; the entry screen falls back to 1 and the
  /// user can correct it manually.
  Future<double?> getExchangeRate({
    required String companyId,
    required String locationId,
    required String fromCurrency,
    required String toCurrency,
    required String rateDate,
  }) async {
    try {
      final res = await _dio.post('/rpc/fn_get_exchange_rate', data: {
        'p_company_id':    companyId,
        'p_location_id':   locationId,
        'p_from_currency': fromCurrency,
        'p_to_currency':   toCurrency,
        'p_rate_date':     rateDate,
        'p_rate_type':     'SELLING',
      });
      return (res.data as num?)?.toDouble();
    } on DioException {
      return null;
    }
  }

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required String userId,
  }) async {
    final res = await _dio.post('/rpc/fn_save_price_master_batch', data: {
      'p_header': header,
      'p_lines':  lines,
      'p_user_id': userId,
    });
    return res.data as String;
  }

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String entryNo,
    required String entryDate,
    required String approvedBy,
  }) async {
    await _dio.post('/rpc/fn_approve_price_master_batch', data: {
      'p_client_id':   clientId,
      'p_company_id':  companyId,
      'p_entry_no':    entryNo,
      'p_entry_date':  entryDate,
      'p_approved_by': approvedBy,
    });
  }
}
