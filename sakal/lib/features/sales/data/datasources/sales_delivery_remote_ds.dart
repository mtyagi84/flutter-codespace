import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';

class SalesDeliveryRemoteDs {
  final Dio _dio = DioClient.instance;

  static const _headerSelect = '*,'
      'customer:rim_accounts!customer_id(account_code,account_name),'
      'location:ric_locations!location_id(location_name)';

  Future<List<Map<String, dynamic>>> listDeliveries({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'select':     _headerSelect,
      'order':      'delivery_date.desc,delivery_no.desc',
      'limit':      '$limit',
      'offset':     '$offset',
    };
    if (status != null && status.isNotEmpty) params['status'] = 'eq.$status';
    if (search != null && search.isNotEmpty) params['or'] = '(delivery_no.ilike.*$search*,invoice_no.ilike.*$search*)';
    final res = await _dio.get('/rih_sales_delivery_headers', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String deliveryNo,
    String? deliveryDate,
  }) async {
    final params = <String, dynamic>{
      'client_id':   'eq.$clientId',
      'company_id':  'eq.$companyId',
      'delivery_no': 'eq.$deliveryNo',
      'is_deleted':  'eq.false',
      'select':      _headerSelect,
      'order':       'delivery_date.desc',
      'limit':       '1',
    };
    if (deliveryDate != null && deliveryDate.isNotEmpty) params['delivery_date'] = 'eq.$deliveryDate';
    final res = await _dio.get('/rih_sales_delivery_headers', queryParameters: params);
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String deliveryNo,
    required String deliveryDate,
  }) async {
    final res = await _dio.get('/rid_sales_delivery_lines', queryParameters: {
      'client_id':    'eq.$clientId', 'company_id': 'eq.$companyId',
      'delivery_no':  'eq.$deliveryNo', 'delivery_date': 'eq.$deliveryDate',
      'is_deleted':   'eq.false',
      'select':       'serial_no,invoice_line_serial,product_id,barcode,uom_id,uom_conversion_factor,'
          'qty_pack,qty_loose,base_qty,'
          'product:rim_products!product_id(product_code,product_name,tracking_type),'
          'uom:rim_common_masters!uom_id(description)',
      'order':        'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Invoices eligible for a new Delivery — sourced from the pending-
  /// delivery rollup view, never rih_sales_invoices directly (that view
  /// already filters to stock_dispatch_mode='DEFERRED' AND status=
  /// 'APPROVED' AND pending_qty > 0 via its own delivery_status column).
  /// Same "picker is UX only" convention as every prior picker — the
  /// row-locked cap check in fn_approve_sales_delivery is authoritative.
  Future<List<Map<String, dynamic>>> getPendingDeliveryInvoices({
    required String clientId,
    required String companyId,
    String? search,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId', 'company_id': 'eq.$companyId',
      'delivery_status': 'in.(PENDING,PARTIALLY_DELIVERED)',
      'select':     'invoice_no,invoice_date,location_id,customer_id,total_qty,delivered_qty,pending_qty,delivery_status,'
          'customer:rim_accounts!customer_id(account_code,account_name),'
          'location:ric_locations!location_id(location_name)',
      'order':      'invoice_date.desc',
      'limit':      '50',
    };
    if (search != null && search.isNotEmpty) params['invoice_no'] = 'ilike.*$search*';
    final res = await _dio.get('/v_sales_invoice_delivery_status', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// A single invoice's own pending-delivery rollup — used by the Sales
  /// Invoice list/entry screens' read-only status badge.
  Future<Map<String, dynamic>?> getDeliveryStatusForInvoice({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  }) async {
    final res = await _dio.get('/v_sales_invoice_delivery_status', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'invoice_no': 'eq.$invoiceNo', 'invoice_date': 'eq.$invoiceDate',
      'select': 'total_qty,delivered_qty,pending_qty,delivery_status',
      'limit': '1',
    });
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  /// Bulk variant for the Sales Invoice LIST screen — one call for every
  /// DEFERRED invoice on the current page rather than N calls.
  Future<List<Map<String, dynamic>>> getDeliveryStatusForInvoices({
    required String clientId,
    required String companyId,
    required List<String> invoiceNos,
  }) async {
    if (invoiceNos.isEmpty) return [];
    final res = await _dio.get('/v_sales_invoice_delivery_status', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'invoice_no': 'in.(${invoiceNos.join(',')})',
      'select': 'invoice_no,invoice_date,total_qty,delivered_qty,pending_qty,delivery_status',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getInvoiceLines({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  }) async {
    final res = await _dio.get('/rid_sales_invoice_lines', queryParameters: {
      'client_id':  'eq.$clientId', 'company_id': 'eq.$companyId',
      'invoice_no': 'eq.$invoiceNo', 'invoice_date': 'eq.$invoiceDate',
      'is_deleted': 'eq.false',
      'select':     'serial_no,product_id,barcode,uom_id,uom_conversion_factor,base_qty,delivered_qty,'
          'product:rim_products!product_id(product_code,product_name,tracking_type),'
          'uom:rim_common_masters!uom_id(description)',
      'order':      'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Live batch candidates for FEFO allocation — a DEFERRED invoice never
  /// staged rid_transaction_line_batches rows (fn_save_sales_invoice
  /// skips that entirely when dispatch is deferred), so unlike Sales
  /// Return there is no source-document allocation to scope against.
  /// Same call Sales Invoice's own DIRECT-mode dispatch already uses.
  Future<List<Map<String, dynamic>>> getBatchStockBalance({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) async {
    final res = await _dio.get('/v_batch_stock_balance', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'location_id': 'eq.$locationId', 'product_id': 'eq.$productId',
      'balance': 'gt.0',
      'select': 'batch_no,expiry_date,manufacturing_date,balance',
      'order': 'expiry_date.asc.nullslast',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getSerialStockStatus({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) async {
    final res = await _dio.get('/v_serial_stock_status', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'location_id': 'eq.$locationId', 'product_id': 'eq.$productId',
      'status': 'eq.IN_STOCK',
      'select': 'serial_no',
      'order': 'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// A delivery's own already-saved batch/serial allocation — for
  /// reopening a DRAFT.
  Future<List<Map<String, dynamic>>> getDeliveryLineBatches({
    required String clientId,
    required String companyId,
    required String deliveryNo,
    required String deliveryDate,
  }) async {
    final res = await _dio.get('/rid_transaction_line_batches', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'source_doc_type': 'eq.SALES_DELIVERY', 'source_doc_no': 'eq.$deliveryNo', 'source_doc_date': 'eq.$deliveryDate',
      'select': 'line_serial,batch_no,expiry_date,manufacturing_date,base_qty',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getDeliveryLineSerials({
    required String clientId,
    required String companyId,
    required String deliveryNo,
    required String deliveryDate,
  }) async {
    final res = await _dio.get('/rid_transaction_line_serials', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'source_doc_type': 'eq.SALES_DELIVERY', 'source_doc_no': 'eq.$deliveryNo', 'source_doc_date': 'eq.$deliveryDate',
      'select': 'line_serial,serial_no',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Customer's saved delivery/ship-to locations (migration 100).
  Future<List<Map<String, dynamic>>> getCustomerDeliveryLocations({
    required String clientId,
    required String companyId,
    required String customerId,
  }) async {
    final res = await _dio.get('/rim_customer_delivery_locations', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'customer_id': 'eq.$customerId', 'is_active': 'eq.true', 'is_deleted': 'eq.false',
      'select': 'id,location_name,address_line1,address_line2,city_id,contact_person,contact_phone,is_default,'
          'city:rim_cities!city_id(city_name)',
      'order': 'is_default.desc,location_name.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<String> saveCustomerDeliveryLocation({
    required Map<String, dynamic> payload,
    required bool isNew,
    required String userId,
  }) async {
    if (isNew) {
      final res = await _dio.post('/rim_customer_delivery_locations', data: {...payload, 'created_by': userId});
      return (res.data is List && (res.data as List).isNotEmpty) ? (res.data as List).first['id'] as String : payload['id'] as String;
    } else {
      await _dio.patch('/rim_customer_delivery_locations',
          queryParameters: {'id': 'eq.${payload['id']}'},
          data: {...payload, 'updated_by': userId});
      return payload['id'] as String;
    }
  }

  Future<void> deleteCustomerDeliveryLocation({required String id, required String userId}) async {
    await _dio.patch('/rim_customer_delivery_locations',
        queryParameters: {'id': 'eq.$id'},
        data: {'is_deleted': true, 'updated_by': userId});
  }

  /// Transport Details (migration 101, generic table) for this delivery.
  Future<Map<String, dynamic>?> getTransportDetails({
    required String clientId,
    required String companyId,
    required String deliveryNo,
    required String deliveryDate,
  }) async {
    final res = await _dio.get('/rid_transport_details', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'source_doc_type': 'eq.SALES_DELIVERY', 'source_doc_no': 'eq.$deliveryNo', 'source_doc_date': 'eq.$deliveryDate',
      'select': 'vehicle_no,transporter_name,driver_name,driver_phone,remarks',
      'limit': '1',
    });
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  Future<List<Map<String, dynamic>>> getUsersForAutocomplete({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_users', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_active':  'eq.true',
      'is_deleted': 'eq.false',
      'select':     'id,full_name',
      'order':      'full_name.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    Map<String, dynamic>? transport,
    required String userId,
  }) async {
    final res = await _dio.post('/rpc/fn_save_sales_delivery', data: {
      'p_header':    header,
      'p_lines':     lines,
      'p_batches':   batches,
      'p_serials':   serials,
      'p_transport': transport,
      'p_user_id':   userId,
    });
    return res.data as String;
  }

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String deliveryNo,
    required String deliveryDate,
    required String approvedBy,
  }) async {
    await _dio.post('/rpc/fn_approve_sales_delivery', data: {
      'p_client_id':     clientId,
      'p_company_id':    companyId,
      'p_delivery_no':   deliveryNo,
      'p_delivery_date': deliveryDate,
      'p_approved_by':   approvedBy,
    });
  }

  /// Online-only — Manager/Pending-Approvals review queries a plain
  /// status='DRAFT' filter, same shape as Sales Invoice's own
  /// listDraftInvoicesForReview.
  Future<List<Map<String, dynamic>>> listDraftDeliveriesForReview({
    required String clientId,
    required String companyId,
    required String locationId,
  }) async {
    final res = await _dio.get('/rih_sales_delivery_headers', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'location_id': 'eq.$locationId', 'status': 'eq.DRAFT', 'is_deleted': 'eq.false',
      'select': _headerSelect,
      'order': 'delivery_date.asc,delivery_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<Map<String, dynamic>?> getStockPreview({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) async {
    final res = await _dio.get('/rim_product_location', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'location_id': 'eq.$locationId', 'product_id': 'eq.$productId',
      'select': 'current_stock',
      'limit': '1',
    });
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  /// Which vouchers this delivery posted — source_doc_type/no/date live
  /// on rih_finance_headers, not rid_finance_lines, so this is always a
  /// two-step lookup, same pattern as Sales Return's own getPostedVouchers.
  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String deliveryNo,
  }) async {
    final res = await _dio.get('/rih_finance_headers', queryParameters: {
      'client_id':       'eq.$clientId', 'company_id': 'eq.$companyId',
      'source_doc_type': 'eq.SALES_DELIVERY', 'source_doc_no': 'eq.$deliveryNo',
      'is_deleted':      'eq.false',
      'select':          'trans_no,trans_date,voucher_type_code',
      'order':           'trans_date.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getPostedVoucherLines({
    required String clientId,
    required String companyId,
    required String voucherNo,
    required String voucherDate,
  }) async {
    final res = await _dio.get('/rid_finance_lines', queryParameters: {
      'client_id':  'eq.$clientId', 'company_id': 'eq.$companyId',
      'trans_no':   'eq.$voucherNo', 'trans_date': 'eq.$voucherDate',
      'is_deleted': 'eq.false',
      'select':     'serial_no,trans_no,trans_nature,trans_amount,'
          'account:rim_accounts!account_id(account_code,account_name)',
      'order':      'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }
}
