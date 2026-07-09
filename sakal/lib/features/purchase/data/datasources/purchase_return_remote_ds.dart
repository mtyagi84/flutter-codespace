import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';
import '../models/purchase_return_model.dart';

class PurchaseReturnRemoteDs {
  final Dio _dio = DioClient.instance;

  static const _headerSelect = '*,'
      'supplier:rim_accounts!supplier_id(account_code,account_name),'
      'location:ric_locations!location_id(location_name),'
      'currency:rim_currencies!return_currency_id(currency_id)';

  // ── List / Header ────────────────────────────────────────────────────────────

  Future<List<PurchaseReturnModel>> listPurchaseReturns({
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
      'order':      'return_date.desc,return_no.desc',
      'limit':      '$limit',
      'offset':     '$offset',
    };
    if (status != null && status.isNotEmpty) params['status'] = 'eq.$status';
    if (search != null && search.isNotEmpty) params['return_no'] = 'ilike.*$search*';
    final res = await _dio.get('/rih_purchase_return_headers', queryParameters: params);
    return (res.data as List).map((e) => PurchaseReturnModel.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<PurchaseReturnModel?> getHeader({
    required String clientId,
    required String companyId,
    required String returnNo,
    String? returnDate,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'return_no':  'eq.$returnNo',
      'is_deleted': 'eq.false',
      'select':     _headerSelect,
      'order':      'return_date.desc',
      'limit':      '1',
    };
    if (returnDate != null && returnDate.isNotEmpty) params['return_date'] = 'eq.$returnDate';
    final res = await _dio.get('/rih_purchase_return_headers', queryParameters: params);
    final list = res.data as List;
    return list.isNotEmpty ? PurchaseReturnModel.fromJson(list.first as Map<String, dynamic>) : null;
  }

  /// Every voucher this return posted (up to two — a JV for the unbilled
  /// portion, an SDN for the billed portion) — found by source doc, same
  /// pattern as Purchase Bill's PUR+EXC pair.
  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String returnNo,
  }) async {
    final res = await _dio.get('/rih_finance_headers', queryParameters: {
      'client_id':      'eq.$clientId',
      'company_id':     'eq.$companyId',
      'source_doc_type': 'eq.PURCHASE_RETURN',
      'source_doc_no':   'eq.$returnNo',
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
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'trans_no':   'eq.$voucherNo',
      'trans_date': 'eq.$voucherDate',
      'is_deleted': 'eq.false',
      'select':     'serial_no,trans_no,trans_nature,trans_amount,'
          'account:rim_accounts!account_id(account_code,account_name)',
      'order':      'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  // ── Supplier -> GRN picker ────────────────────────────────────────────────

  /// Distinct suppliers with at least one APPROVED GRN — returns can
  /// reference billed or unbilled GRNs alike (unlike Purchase Bill), so
  /// there's no "not yet billed" filter here.
  Future<List<Map<String, dynamic>>> getSuppliersWithApprovedGrns({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rih_grn_headers', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'status':     'eq.APPROVED',
      'select':     'supplier:rim_accounts!supplier_id(id,account_code,account_name)',
    });
    final seen = <String>{};
    final result = <Map<String, dynamic>>[];
    for (final e in res.data as List) {
      final supplier = (e as Map<String, dynamic>)['supplier'] as Map<String, dynamic>?;
      if (supplier == null) continue;
      if (seen.add(supplier['id'] as String)) result.add(supplier);
    }
    result.sort((a, b) => (a['account_code'] as String? ?? '').compareTo(b['account_code'] as String? ?? ''));
    return result;
  }

  /// This supplier's APPROVED GRNs, billed or not — billed_invoice_no tells
  /// the entry screen which financial path (JV vs SDN) a line will take.
  Future<List<Map<String, dynamic>>> getGrnsForSupplier({
    required String clientId,
    required String companyId,
    required String supplierId,
  }) async {
    final res = await _dio.get('/rih_grn_headers', queryParameters: {
      'client_id':   'eq.$clientId',
      'company_id':  'eq.$companyId',
      'supplier_id': 'eq.$supplierId',
      'is_deleted':  'eq.false',
      'status':      'eq.APPROVED',
      'select':      'grn_no,grn_date,grn_currency_id,billed_invoice_no,'
          'currency:rim_currencies!grn_currency_id(currency_id)',
      'order':       'grn_date.asc,grn_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Which of this supplier's GRNs have already been returned IN FULL
  /// (every line's total returned qty across every APPROVED return >= what
  /// it originally received) — used to disable/flag them in the picker so
  /// a GRN with nothing left to give doesn't keep inviting re-selection.
  /// Partial returns are untouched: a GRN not fully returned yet stays
  /// fully selectable, same as before.
  Future<Set<String>> getFullyReturnedGrnKeys({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/v_grn_return_status', queryParameters: {
      'client_id':      'eq.$clientId',
      'company_id':     'eq.$companyId',
      'fully_returned': 'eq.true',
      'select':         'grn_no,grn_date',
    });
    return (res.data as List)
        .map((e) => '${(e as Map<String, dynamic>)['grn_no']}|${e['grn_date']}')
        .toSet();
  }

  /// A GRN's own lines — GRN qty pre-fills as the suggested (editable)
  /// return qty on the entry screen.
  Future<List<Map<String, dynamic>>> getGrnLines({
    required String clientId,
    required String companyId,
    required String grnNo,
    required String grnDate,
  }) async {
    final res = await _dio.get('/rid_grn_lines', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'grn_no':     'eq.$grnNo',
      'grn_date':   'eq.$grnDate',
      'is_deleted': 'eq.false',
      'select':     'serial_no,product_id,uom_id,uom_conversion_factor,base_qty,rate,'
          'tax_group_id,gross_amount,tax_amount,final_amount,source_po_order_no,barcode,'
          'product:rim_products!product_id(product_code,product_name,tracking_type),'
          'uom:rim_common_masters!uom_id(description),'
          'tax_group:rim_tax_groups!tax_group_id(group_name)',
      'order':      'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// The batches this specific GRN line originally received — candidates the
  /// user can pick to return from. Actual returnability is capped by each
  /// batch's CURRENT ledger balance (getBatchBalance below), not just what
  /// was received here — some of it may have moved on since (sold, an
  /// earlier partial return, etc).
  Future<List<Map<String, dynamic>>> getGrnLineBatches({
    required String clientId,
    required String companyId,
    required String grnNo,
    required String grnDate,
    required int    lineSerial,
  }) async {
    final res = await _dio.get('/rid_transaction_line_batches', queryParameters: {
      'client_id':       'eq.$clientId',
      'company_id':      'eq.$companyId',
      'source_doc_type': 'eq.GRN',
      'source_doc_no':   'eq.$grnNo',
      'source_doc_date': 'eq.$grnDate',
      'line_serial':     'eq.$lineSerial',
      'select':          'batch_no,expiry_date,manufacturing_date,base_qty',
      'order':           'batch_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// The serials this specific GRN line originally received — same
  /// candidate-list role as getGrnLineBatches above.
  Future<List<Map<String, dynamic>>> getGrnLineSerials({
    required String clientId,
    required String companyId,
    required String grnNo,
    required String grnDate,
    required int    lineSerial,
  }) async {
    final res = await _dio.get('/rid_transaction_line_serials', queryParameters: {
      'client_id':       'eq.$clientId',
      'company_id':      'eq.$companyId',
      'source_doc_type': 'eq.GRN',
      'source_doc_no':   'eq.$grnNo',
      'source_doc_date': 'eq.$grnDate',
      'line_serial':     'eq.$lineSerial',
      'select':          'serial_no',
      'order':           'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Current remaining balance for one batch at this location — a UX hint
  /// only ("Available: N"); the real enforcement is server-side, in
  /// fn_post_stock_movement's strict per-batch check (migration 063).
  Future<num> getBatchBalance({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
    required String batchNo,
  }) async {
    final res = await _dio.get('/v_batch_stock_balance', queryParameters: {
      'client_id':   'eq.$clientId',
      'company_id':  'eq.$companyId',
      'location_id': 'eq.$locationId',
      'product_id':  'eq.$productId',
      'batch_no':    'eq.$batchNo',
      'select':      'balance',
    });
    final list = res.data as List;
    if (list.isEmpty) return 0;
    return (list.first as Map<String, dynamic>)['balance'] as num? ?? 0;
  }

  /// Current status (IN_STOCK / OUT) for one serial at this location — same
  /// UX-hint role as getBatchBalance above.
  Future<String> getSerialStatus({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
    required String serialNo,
  }) async {
    final res = await _dio.get('/v_serial_stock_status', queryParameters: {
      'client_id':   'eq.$clientId',
      'company_id':  'eq.$companyId',
      'location_id': 'eq.$locationId',
      'product_id':  'eq.$productId',
      'serial_no':   'eq.$serialNo',
      'select':      'status',
    });
    final list = res.data as List;
    if (list.isEmpty) return 'OUT';
    return (list.first as Map<String, dynamic>)['status'] as String? ?? 'OUT';
  }

  /// A GRN's own additional charges — populate as editable defaults.
  Future<List<Map<String, dynamic>>> getGrnCharges({
    required String clientId,
    required String companyId,
    required String grnNo,
    required String grnDate,
  }) async {
    final res = await _dio.get('/rid_grn_charge_lines', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'grn_no':     'eq.$grnNo',
      'grn_date':   'eq.$grnDate',
      'is_deleted': 'eq.false',
      'select':     'serial_no,charge_id,charge_name,is_taxable,tax_id,nature,gl_account_id,amount,tax_amount',
      'order':      'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  // ── Reload an existing return's own lines/charges/allocations ────────────
  // Needed both to re-open a DRAFT for further editing and to display an
  // APPROVED return (view + print) — previously missing entirely, so both
  // cases showed a blank Return Lines/Charges section.

  Future<List<Map<String, dynamic>>> getReturnLines({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
  }) async {
    final res = await _dio.get('/rid_purchase_return_lines', queryParameters: {
      'client_id':   'eq.$clientId',
      'company_id':  'eq.$companyId',
      'return_no':   'eq.$returnNo',
      'return_date': 'eq.$returnDate',
      'is_deleted':  'eq.false',
      'select':      'serial_no,source_grn_no,source_grn_date,source_grn_line_serial,product_id,qty_pack,qty_loose,base_qty',
      'order':       'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getReturnCharges({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
  }) async {
    final res = await _dio.get('/rid_purchase_return_charge_lines', queryParameters: {
      'client_id':   'eq.$clientId',
      'company_id':  'eq.$companyId',
      'return_no':   'eq.$returnNo',
      'return_date': 'eq.$returnDate',
      'is_deleted':  'eq.false',
      'select':      'serial_no,charge_id,charge_name,is_taxable,tax_id,nature,gl_account_id,amount,tax_amount,'
          'source_grn_no,source_grn_date',
      'order':       'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// This return line's own previously-saved batch allocation (as opposed to
  /// getGrnLineBatches, which lists the GRN's ORIGINAL candidates) — used to
  /// pre-select/pre-fill the picker when reopening a DRAFT or viewing an
  /// APPROVED return.
  Future<List<Map<String, dynamic>>> getReturnLineBatches({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
    required int    lineSerial,
  }) async {
    final res = await _dio.get('/rid_transaction_line_batches', queryParameters: {
      'client_id':       'eq.$clientId',
      'company_id':      'eq.$companyId',
      'source_doc_type': 'eq.PURCHASE_RETURN',
      'source_doc_no':   'eq.$returnNo',
      'source_doc_date': 'eq.$returnDate',
      'line_serial':     'eq.$lineSerial',
      'select':          'batch_no,base_qty',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// This return line's own previously-saved serial allocation — same role
  /// as getReturnLineBatches above.
  Future<List<Map<String, dynamic>>> getReturnLineSerials({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
    required int    lineSerial,
  }) async {
    final res = await _dio.get('/rid_transaction_line_serials', queryParameters: {
      'client_id':       'eq.$clientId',
      'company_id':      'eq.$companyId',
      'source_doc_type': 'eq.PURCHASE_RETURN',
      'source_doc_no':   'eq.$returnNo',
      'source_doc_date': 'eq.$returnDate',
      'line_serial':     'eq.$lineSerial',
      'select':          'serial_no',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Common-master values for a given type_key (e.g. 'PURCHASE_RETURN_REASON')
  /// — two-step lookup since rim_common_masters filters by type_id (UUID),
  /// same pattern as grn_remote_ds.dart/purchase_order_remote_ds.dart.
  Future<List<Map<String, dynamic>>> getCommonMastersByType({
    required String clientId,
    required String companyId,
    required String typeKey,
  }) async {
    final typeRes = await _dio.get('/rim_common_master_types', queryParameters: {
      'type_key': 'eq.$typeKey',
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

  // ── Save / Approve ────────────────────────────────────────────────────────────

  /// Returns the assigned return_no.
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required List<Map<String, dynamic>> charges,
    required String userId,
  }) async {
    final res = await _dio.post('/rpc/fn_save_purchase_return', data: {
      'p_header':  header,
      'p_lines':   lines,
      'p_batches': batches,
      'p_serials': serials,
      'p_charges': charges,
      'p_user_id': userId,
    });
    return res.data as String;
  }

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
    required bool   reopenPo,
    required String approvedBy,
  }) async {
    await _dio.post('/rpc/fn_approve_purchase_return', data: {
      'p_client_id':   clientId,
      'p_company_id':  companyId,
      'p_return_no':   returnNo,
      'p_return_date': returnDate,
      'p_reopen_po':   reopenPo,
      'p_approved_by': approvedBy,
    });
  }
}
