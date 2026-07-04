import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';
import '../models/grn_charge_line_model.dart';
import '../models/grn_line_model.dart';
import '../models/grn_model.dart';

class GrnRemoteDs {
  final Dio _dio = DioClient.instance;

  static const _headerSelect = '*,'
      'supplier:rim_accounts!supplier_id(account_code,account_name),'
      'location:ric_locations!location_id(location_name),'
      'currency:rim_currencies!grn_currency_id(currency_id)';

  static const _lineSelect = '*,'
      'product:rim_products!product_id(product_code,product_name),'
      'uom:rim_common_masters!uom_id(description),'
      'tax_group:rim_tax_groups!tax_group_id(group_name)';

  /// The GL lines fn_post_voucher created when this GRN was approved — for
  /// the read-only "Posted Journal Entries" section on an APPROVED GRN.
  /// Resolves the ledger name via a join rather than a client-side lookup
  /// list, since GL lines can touch Stock/Accrual/Tax/Charge accounts that
  /// were never loaded into the screen's own supplier picker.
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

  // ── List ───────────────────────────────────────────────────────────────────

  Future<List<GrnModel>> listGrns({
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
      'order':      'grn_date.desc,grn_no.desc',
      'limit':      '$limit',
      'offset':     '$offset',
    };
    if (status != null && status.isNotEmpty) params['status'] = 'eq.$status';
    if (search != null && search.isNotEmpty) params['grn_no'] = 'ilike.*$search*';
    final res = await _dio.get('/rih_grn_headers', queryParameters: params);
    return (res.data as List).map((e) => GrnModel.fromJson(e as Map<String, dynamic>)).toList();
  }

  // ── Header / Lines / Charges ─────────────────────────────────────────────────

  Future<GrnModel?> getHeader({
    required String clientId,
    required String companyId,
    required String grnNo,
    String? grnDate,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'grn_no':     'eq.$grnNo',
      'is_deleted': 'eq.false',
      'select':     _headerSelect,
      'order':      'grn_date.desc',
      'limit':      '1',
    };
    if (grnDate != null && grnDate.isNotEmpty) params['grn_date'] = 'eq.$grnDate';
    final res = await _dio.get('/rih_grn_headers', queryParameters: params);
    final list = res.data as List;
    return list.isNotEmpty ? GrnModel.fromJson(list.first as Map<String, dynamic>) : null;
  }

  Future<List<GrnLineModel>> getLines({
    required String clientId,
    required String companyId,
    required String grnNo,
    required String grnDate,
  }) async {
    final linesRes = await _dio.get('/rid_grn_lines', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'grn_no':     'eq.$grnNo',
      'grn_date':   'eq.$grnDate',
      'is_deleted': 'eq.false',
      'select':     _lineSelect,
      'order':      'serial_no.asc',
    });
    final lines = (linesRes.data as List)
        .map((e) => GrnLineModel.fromJson(e as Map<String, dynamic>))
        .toList();
    if (lines.isEmpty) return lines;

    // rid_transaction_line_batches/serials are keyed by source_doc_type/no/date,
    // not a real FK PostgREST can embed — fetched separately and grouped by
    // line_serial onto each line below.
    final commonParams = {
      'client_id':       'eq.$clientId',
      'company_id':      'eq.$companyId',
      'source_doc_type': 'eq.GRN',
      'source_doc_no':   'eq.$grnNo',
      'source_doc_date': 'eq.$grnDate',
      'select':          '*',
    };
    final results = await Future.wait([
      _dio.get('/rid_transaction_line_batches', queryParameters: commonParams),
      _dio.get('/rid_transaction_line_serials', queryParameters: commonParams),
    ]);

    final batchesByLine = <int, List<GrnBatchModel>>{};
    for (final e in results[0].data as List) {
      final m = e as Map<String, dynamic>;
      batchesByLine.putIfAbsent(m['line_serial'] as int, () => []).add(GrnBatchModel.fromJson(m));
    }
    final serialsByLine = <int, List<GrnSerialModel>>{};
    for (final e in results[1].data as List) {
      final m = e as Map<String, dynamic>;
      serialsByLine.putIfAbsent(m['line_serial'] as int, () => []).add(GrnSerialModel.fromJson(m));
    }

    return lines.map((l) => l.withChildren(
      batches: batchesByLine[l.serialNo] ?? const [],
      serials: serialsByLine[l.serialNo] ?? const [],
    )).toList();
  }

  Future<List<GrnChargeLineModel>> getCharges({
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
      'select':     '*',
      'order':      'serial_no.asc',
    });
    return (res.data as List)
        .map((e) => GrnChargeLineModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ── Save / Approve ────────────────────────────────────────────────────────────

  /// Returns the assigned grn_no.
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required List<Map<String, dynamic>> charges,
    required String userId,
  }) async {
    final res = await _dio.post('/rpc/fn_save_grn', data: {
      'p_header':   header,
      'p_lines':    lines,
      'p_batches':  batches,
      'p_serials':  serials,
      'p_charges':  charges,
      'p_user_id':  userId,
    });
    return res.data as String;
  }

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String grnNo,
    required String grnDate,
    required String approvedBy,
  }) async {
    await _dio.post('/rpc/fn_approve_grn', data: {
      'p_client_id':   clientId,
      'p_company_id':  companyId,
      'p_grn_no':      grnNo,
      'p_grn_date':    grnDate,
      'p_approved_by': approvedBy,
    });
  }

  // ── Against-PO consolidation ──────────────────────────────────────────────────

  /// Open POs for a supplier that can still receive stock — the picker list
  /// for "Add from PO" in Against-PO mode. A GRN may consolidate lines from
  /// more than one of these.
  Future<List<Map<String, dynamic>>> getOpenPurchaseOrdersForSupplier({
    required String clientId,
    required String companyId,
    required String supplierId,
  }) async {
    final res = await _dio.get('/rih_purchase_orders', queryParameters: {
      'client_id':   'eq.$clientId',
      'company_id':  'eq.$companyId',
      'supplier_id': 'eq.$supplierId',
      'is_deleted':  'eq.false',
      'status':      'in.(APPROVED,PARTIALLY_RECEIVED)',
      'select':      'order_no,order_date,po_currency_id,rate_to_base,rate_to_local,bill_to,ship_to,'
          'currency:rim_currencies!po_currency_id(currency_id)',
      'order':       'order_date.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// This PO's lines that still have qty outstanding, with the pending
  /// quantity pre-computed onto each row as 'pending_qty'.
  ///
  /// qty_received only reflects APPROVED GRNs (fn_approve_grn increments it
  /// at approval time) — a second, still-DRAFT GRN against the same PO would
  /// otherwise see the full original ordered quantity as available, letting
  /// two drafts both claim the same stock. [excludeGrnNo] is the GRN
  /// currently being edited, if any — its own lines must not be treated as
  /// "already committed by someone else".
  Future<List<Map<String, dynamic>>> getPendingPoLines({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
    String? excludeGrnNo,
  }) async {
    final res = await _dio.get('/rid_purchase_order_lines', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'order_no':   'eq.$orderNo',
      'order_date': 'eq.$orderDate',
      'is_deleted': 'eq.false',
      'select':     '*,'
          'product:rim_products!product_id(product_code,product_name,tracking_type),'
          'uom:rim_common_masters!uom_id(description),'
          'tax_group:rim_tax_groups!tax_group_id(group_name)',
      'order':      'serial_no.asc',
    });
    final rows = List<Map<String, dynamic>>.from(res.data as List);

    final committedByLine = await _committedDraftQtyByPoLine(
      clientId: clientId, companyId: companyId, orderNo: orderNo, orderDate: orderDate,
      excludeGrnNo: excludeGrnNo,
    );

    return rows.where((r) {
      final serialNo  = r['serial_no'] as int;
      final ordered   = (r['base_qty'] as num? ?? 0).toDouble();
      final received  = (r['qty_received'] as num? ?? 0).toDouble();
      final committed = committedByLine[serialNo] ?? 0;
      final pending   = ordered - received - committed;
      r['pending_qty'] = pending;
      return pending > 0.0001;
    }).toList();
  }

  /// Quantity of this PO already claimed by OTHER still-DRAFT GRNs (approved
  /// GRNs are already reflected in rid_purchase_order_lines.qty_received, so
  /// including them here too would double-subtract). Keyed by
  /// source_po_line_serial.
  Future<Map<int, double>> _committedDraftQtyByPoLine({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
    String? excludeGrnNo,
  }) async {
    final linesRes = await _dio.get('/rid_grn_lines', queryParameters: {
      'client_id':            'eq.$clientId',
      'company_id':           'eq.$companyId',
      'source_po_order_no':   'eq.$orderNo',
      'source_po_order_date': 'eq.$orderDate',
      'is_deleted':           'eq.false',
      'select':               'grn_no,source_po_line_serial,base_qty',
    });
    final lines = List<Map<String, dynamic>>.from(linesRes.data as List);
    if (lines.isEmpty) return {};

    final grnNos = lines.map((l) => l['grn_no'] as String)
        .where((g) => g != excludeGrnNo).toSet();
    if (grnNos.isEmpty) return {};

    final headersRes = await _dio.get('/rih_grn_headers', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'grn_no':     'in.(${grnNos.join(',')})',
      'status':     'eq.DRAFT',
      'select':     'grn_no',
    });
    final draftGrnNos = (headersRes.data as List)
        .map((e) => (e as Map<String, dynamic>)['grn_no'] as String).toSet();
    if (draftGrnNos.isEmpty) return {};

    final result = <int, double>{};
    for (final l in lines) {
      final grnNo = l['grn_no'] as String;
      if (grnNo == excludeGrnNo || !draftGrnNos.contains(grnNo)) continue;
      final serialNo = l['source_po_line_serial'] as int?;
      if (serialNo == null) continue;
      result[serialNo] = (result[serialNo] ?? 0) + (l['base_qty'] as num? ?? 0).toDouble();
    }
    return result;
  }

  /// Distinct suppliers with at least one PO still open for receipt — the
  /// candidate list for the Against-PO wizard's first step.
  Future<List<Map<String, dynamic>>> getSuppliersWithOpenPos({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rih_purchase_orders', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'status':     'in.(APPROVED,PARTIALLY_RECEIVED)',
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

  /// Charge lines from a consolidated PO, seeded as editable GRN charge
  /// defaults — the real, final figures are decided at GRN, not PO.
  Future<List<Map<String, dynamic>>> getPoChargeLinesForOrder({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  }) async {
    final res = await _dio.get('/rid_po_charge_lines', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'order_no':   'eq.$orderNo',
      'order_date': 'eq.$orderDate',
      'is_deleted': 'eq.false',
      'select':     '*',
      'order':      'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  // ── Reference data ────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getAdditionalCharges({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_additional_charges', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'is_active':  'eq.true',
      'or':         '(applicable_on.eq.PURCHASE,applicable_on.eq.BOTH)',
      'select':     '*',
      'order':      'sort_order.asc,charge_name.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Products for the Direct-mode line picker — includes tracking_type so the
  /// entry screen knows whether to open a batch/serial capture sub-editor.
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
      'select':     'id,product_code,product_name,base_uom_id,tracking_type,'
          'last_purchase_cost,standard_cost,purchase_tax_group_id,'
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

  /// Same barcode -> product+UOM matching PO uses. See that datasource's
  /// identical method for the full rationale.
  Future<Map<String, dynamic>?> getProductByBarcode({
    required String clientId,
    required String companyId,
    required String barcode,
  }) async {
    final res = await _dio.get('/rim_product_uom', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'barcode':    'eq.$barcode',
      'select':     'uom_id,conversion_factor,'
          'product:rim_products!product_id(id,product_code,product_name,base_uom_id,tracking_type,'
          'last_purchase_cost,standard_cost,purchase_tax_group_id,is_active,is_deleted)',
      'limit':      '1',
    });
    final list = res.data as List;
    if (list.isEmpty) return null;
    final row     = list.first as Map<String, dynamic>;
    final product = row['product'] as Map<String, dynamic>?;
    if (product == null || product['is_deleted'] == true || product['is_active'] == false) return null;
    return {
      ...product,
      'matched_uom_id': row['uom_id'],
      'matched_uom_conversion_factor': row['conversion_factor'],
    };
  }

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

  Future<List<Map<String, dynamic>>> getTaxGroups({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_tax_groups', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'is_active':  'eq.true',
      'or':         '(applicable_on.eq.PURCHASE,applicable_on.eq.BOTH)',
      'select':     'id,group_code,group_name',
      'order':      'group_name.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<Map<String, List<String>>> getTaxGroupMemberTaxIds(List<String> groupIds) async {
    if (groupIds.isEmpty) return {};
    final res = await _dio.get('/rim_tax_group_members', queryParameters: {
      'tax_group_id': 'in.(${groupIds.join(',')})',
      'select':       'tax_group_id,tax_id',
    });
    final result = <String, List<String>>{};
    for (final e in res.data as List) {
      final m = e as Map<String, dynamic>;
      result.putIfAbsent(m['tax_group_id'] as String, () => []).add(m['tax_id'] as String);
    }
    return result;
  }

  Future<Map<String, double>> getTaxRatesByIds({
    required List<String> taxIds,
    required String asOfDate,
  }) async {
    if (taxIds.isEmpty) return {};
    final res = await _dio.get('/rim_tax_rates', queryParameters: {
      'tax_id':      'in.(${taxIds.join(',')})',
      'rate_label':  'eq.STANDARD',
      'is_active':   'eq.true',
      'select':      'tax_id,rate,effective_from,effective_to',
      'order':       'effective_from.desc',
    });
    final asOf   = DateTime.tryParse(asOfDate) ?? DateTime.now();
    final result = <String, double>{};
    for (final e in res.data as List) {
      final m    = e as Map<String, dynamic>;
      final taxId = m['tax_id'] as String;
      if (result.containsKey(taxId)) continue;
      final from = DateTime.tryParse(m['effective_from'] as String? ?? '');
      final to   = m['effective_to'] != null ? DateTime.tryParse(m['effective_to'] as String) : null;
      if (from == null || from.isAfter(asOf)) continue;
      if (to != null && to.isBefore(asOf)) continue;
      result[taxId] = (m['rate'] as num).toDouble();
    }
    return result;
  }

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
        'p_rate_type':     'MID',
      });
      return (res.data as num?)?.toDouble();
    } on DioException {
      return null;
    }
  }
}
