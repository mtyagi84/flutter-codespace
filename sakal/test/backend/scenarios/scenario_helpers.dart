import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

String todayStr() => DateTime.now().toIso8601String().split('T').first;

/// Shared plumbing for the business-scenario integration tests
/// (`test/backend/scenarios/*.dart`). Mirrors CommonRefs's own scope
/// discipline: covers repeated SETUP/VERIFICATION steps only — the RPC
/// calls that ARE the point of a given scenario are always made directly
/// in that scenario's own file, never hidden in here.
class ScenarioHelpers {
  /// Creates + approves a DIRECT-receipt GRN (no PO) for [qty] units of
  /// TestTenantConfig.productId at [rate] — the "establish stock at a
  /// known cost" step nearly every scenario needs before it can sell,
  /// issue, transfer, or adjust. Single GRN, so the resulting weighted-
  /// average cost is exactly [rate]. Returns the grn_no.
  static Future<String> establishStockViaDirectGrn(
    BackendVerifier verifier,
    CommonRefs refs, {
    required double qty,
    required double rate,
    String? locationId,
  }) async {
    final today = todayStr();
    final amount = qty * rate;
    final grnNo = await verifier.rpc('fn_save_grn', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': locationId ?? TestTenantConfig.locationId,
        'grn_no': null,
        'grn_date': today,
        'supplier_id': TestTenantConfig.supplierId,
        'receipt_mode': 'DIRECT',
        'grn_currency_id': refs.currencyId,
        'rate_to_base': 1,
        'rate_to_local': 1,
        'gross_amount': amount,
        'grand_total': amount,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': qty,
          'qty_loose': 0,
          'base_qty': qty,
          'rate': rate,
          'gross_amount': amount,
          'final_amount': amount,
          'base_amount': amount,
          'local_amount': amount,
        },
      ],
      'p_batches': [],
      'p_serials': [],
      'p_charges': [],
      'p_user_id': verifier.userId,
    });
    await verifier.rpc('fn_approve_grn', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_grn_no': grnNo,
      'p_grn_date': today,
      'p_approved_by': verifier.userId,
    });
    return grnNo as String;
  }

  /// Same, but AGAINST a given PO's own order_no/order_date/line serial —
  /// for scenarios that must chain through a real PO first.
  static Future<String> receiveGrnAgainstPo(
    BackendVerifier verifier,
    CommonRefs refs, {
    required String orderNo,
    required String orderDate,
    required double qty,
    required double rate,
    int lineSerial = 1,
  }) async {
    final today = todayStr();
    final amount = qty * rate;
    final grnNo = await verifier.rpc('fn_save_grn', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'grn_no': null,
        'grn_date': today,
        'supplier_id': TestTenantConfig.supplierId,
        'receipt_mode': 'AGAINST_PO',
        'grn_currency_id': refs.currencyId,
        'rate_to_base': 1,
        'rate_to_local': 1,
        'gross_amount': amount,
        'grand_total': amount,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'source_po_order_no': orderNo,
          'source_po_order_date': orderDate,
          'source_po_line_serial': lineSerial,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': qty,
          'qty_loose': 0,
          'base_qty': qty,
          'rate': rate,
          'gross_amount': amount,
          'final_amount': amount,
          'base_amount': amount,
          'local_amount': amount,
          'charge_amount': 0,
          'landed_amount': amount,
        },
      ],
      'p_batches': [],
      'p_serials': [],
      'p_charges': [],
      'p_user_id': verifier.userId,
    });
    await verifier.rpc('fn_approve_grn', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_grn_no': grnNo,
      'p_grn_date': today,
      'p_approved_by': verifier.userId,
    });
    return grnNo as String;
  }

  /// Reads rim_product_location for TestTenantConfig.productId at
  /// [locationId] and returns (currentStock, costPrice).
  static Future<({double currentStock, double costPrice})> stockAt(
    BackendVerifier verifier,
    String locationId,
  ) async {
    final row = await verifier.getOne(
      'rim_product_location',
      {'product_id': 'eq.${TestTenantConfig.productId}', 'location_id': 'eq.$locationId'},
      select: 'current_stock,cost_price',
    );
    return (
      currentStock: (row['current_stock'] as num).toDouble(),
      costPrice: (row['cost_price'] as num).toDouble(),
    );
  }

  /// Finds the posting voucher(s) for a source document — queries
  /// rih_finance_headers by source_doc_type/source_doc_no (optionally
  /// narrowed by voucher_type_code when a doc posts more than one, e.g.
  /// Sales Invoice's SI+COS pair) and returns the matching
  /// rid_finance_lines rows for each header found.
  static Future<List<Map<String, dynamic>>> financeLinesFor(
    BackendVerifier verifier, {
    required String sourceDocType,
    required String sourceDocNo,
    String? voucherTypeCode,
  }) async {
    final filters = <String, String>{
      'source_doc_type': 'eq.$sourceDocType',
      'source_doc_no': 'eq.$sourceDocNo',
    };
    if (voucherTypeCode != null) filters['voucher_type_code'] = 'eq.$voucherTypeCode';
    final headers = await verifier.get('rih_finance_headers', filters, select: 'trans_no,trans_date,voucher_type_code');
    final lines = <Map<String, dynamic>>[];
    for (final h in headers) {
      final rows = await verifier.get(
        'rid_finance_lines',
        {'trans_no': 'eq.${h['trans_no']}', 'trans_date': 'eq.${h['trans_date']}'},
        select: '*',
      );
      lines.addAll(rows);
    }
    return lines;
  }

  /// Asserts a list of finance lines balances (sum(DR base_amount) ==
  /// sum(CR base_amount)) — a sanity check every GL assertion block should
  /// run before checking individual account amounts.
  static void assertLinesBalance(List<Map<String, dynamic>> lines) {
    double dr = 0, cr = 0;
    for (final l in lines) {
      final amt = (l['base_amount'] as num).toDouble();
      if (l['trans_nature'] == 'DR') {
        dr += amt;
      } else if (l['trans_nature'] == 'CR') {
        cr += amt;
      }
    }
    expect(dr, closeTo(cr, 0.01), reason: 'Finance lines must balance: DR=$dr CR=$cr');
  }

  /// Thin wrapper over fn_trial_balance_totals_base — asserts debit==credit
  /// (to a cent) for [dateFrom, dateTo].
  static Future<void> assertTrialBalanceBalances(
    BackendVerifier verifier, {
    required String dateFrom,
    required String dateTo,
  }) async {
    final result = await verifier.rpc('fn_trial_balance_totals_base', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_date_from': dateFrom,
      'p_date_to': dateTo,
    });
    final row = (result as List).first as Map<String, dynamic>;
    final debit = (row['debit'] as num).toDouble();
    final credit = (row['credit'] as num).toDouble();
    expect(debit, closeTo(credit, 0.01),
        reason: 'Trial Balance must balance: debit=$debit credit=$credit');
  }

  /// Thin wrapper over fn_balance_sheet_totals_base — asserts
  /// total_assets == total_liabilities_equity (difference == 0, to a cent).
  static Future<void> assertBalanceSheetBalances(
    BackendVerifier verifier, {
    required String asOfDate,
  }) async {
    final result = await verifier.rpc('fn_balance_sheet_totals_base', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_as_of_date': asOfDate,
    });
    final row = (result as List).first as Map<String, dynamic>;
    final difference = (row['difference'] as num).toDouble();
    expect(difference, closeTo(0, 0.01),
        reason: 'Balance Sheet must balance (Assets = Liabilities + Equity): difference=$difference, row=$row');
  }

  /// The full Purchase-to-Pay chain (PO -> GRN AGAINST_PO -> Purchase
  /// Invoice -> on-account Payment) — reused verbatim by scenario 1 and
  /// scenario 9. Returns the key document numbers/trans_no produced.
  static Future<PurchaseToPayResult> runPurchaseToPayChain(
    BackendVerifier verifier,
    CommonRefs refs, {
    required double qty,
    required double rate,
    required String supplierInvoiceNo,
    required String cashAccountId,
  }) async {
    final today = todayStr();
    final amount = qty * rate;

    final orderNo = await verifier.rpc('fn_save_purchase_order', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'order_no': null,
        'order_date': today,
        'po_type': 'LOCAL',
        'supplier_id': TestTenantConfig.supplierId,
        'po_currency_id': refs.currencyId,
        'rate_to_base': 1,
        'rate_to_local': 1,
        'gross_amount': amount,
        'discount_amount': 0,
        'charges_amount': 0,
        'item_tax_amount': 0,
        'charge_tax_amount': 0,
        'grand_total': amount,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': qty,
          'qty_loose': 0,
          'base_qty': qty,
          'rate': rate,
          'gross_amount': amount,
          'discount_percent': 0,
          'discount_amount': 0,
          'tax_amount': 0,
          'final_amount': amount,
          'base_amount': amount,
          'local_amount': amount,
          'charge_amount': 0,
          'landed_amount': amount,
          'qty_on_hand_at_order': 0,
          'reorder_level_at_order': 0,
        },
      ],
      'p_charges': [],
      'p_payment_terms': [],
      'p_user_id': verifier.userId,
    }) as String;

    await verifier.rpc('fn_approve_purchase_order', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_order_no': orderNo,
      'p_order_date': today,
      'p_approved_by': verifier.userId,
    });

    final grnNo = await receiveGrnAgainstPo(
      verifier, refs,
      orderNo: orderNo, orderDate: today,
      qty: qty, rate: rate,
    );

    final invoiceNo = await verifier.rpc('fn_save_purchase_invoice', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'invoice_no': null,
        'invoice_date': today,
        'supplier_id': TestTenantConfig.supplierId,
        'supplier_invoice_no': supplierInvoiceNo,
        'supplier_invoice_date': today,
        'invoice_currency_id': refs.currencyId,
        'rate_to_base': 1,
        'rate_to_local': 1,
        'taxable_amount': amount,
        'tax_amount': 0,
        'invoice_total': amount,
      },
      'p_grn_refs': [
        {'grn_no': grnNo, 'grn_date': today},
      ],
      'p_user_id': verifier.userId,
    }) as String;

    await verifier.rpc('fn_approve_purchase_invoice', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_invoice_no': invoiceNo,
      'p_invoice_date': today,
      'p_approved_by': verifier.userId,
    });

    // On-account payment settling the full amount.
    final payTransNo = await verifier.rpc('fn_save_finance_voucher', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'trans_no': null,
        'trans_date': today,
        'voucher_type_code': 'CPV',
        'is_on_account': true,
        'remarks': 'QA scenario test - on account payment',
      },
      'p_lines': [
        {
          'serial_no': 1,
          'account_id': TestTenantConfig.supplierId,
          'trans_nature': 'DR',
          'trans_amount': amount,
          'trans_currency': 'USD',
          'base_amount': amount,
          'base_rate': 1,
          'local_amount': amount,
          'local_rate': 1,
          'party_amount': amount,
          'party_currency': 'USD',
          'party_rate': 1,
        },
        {
          'serial_no': 2,
          'account_id': cashAccountId,
          'trans_nature': 'CR',
          'trans_amount': amount,
          'trans_currency': 'USD',
          'base_amount': amount,
          'base_rate': 1,
          'local_amount': amount,
          'local_rate': 1,
          'party_amount': amount,
          'party_currency': 'USD',
          'party_rate': 1,
        },
      ],
      'p_user_id': verifier.userId,
    }) as String;

    await verifier.rpc('fn_post_finance_voucher', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_location_id': TestTenantConfig.locationId,
      'p_trans_no': payTransNo,
      'p_trans_date': today,
      'p_posted_by': verifier.userId,
    });

    return PurchaseToPayResult(
      orderNo: orderNo,
      grnNo: grnNo,
      invoiceNo: invoiceNo,
      paymentTransNo: payTransNo,
      qty: qty,
      rate: rate,
      amount: amount,
      date: today,
    );
  }

  /// The full Order-to-Cash chain (Sales Order -> AGAINST_ORDER Sales
  /// Invoice, deferred -> Sales Delivery -> Sales Return -> Cash Receipt)
  /// — reused verbatim by scenario 2, 9, and 10.
  static Future<OrderToCashResult> runOrderToCashChain(
    BackendVerifier verifier,
    CommonRefs refs, {
    required double buyQty,
    required double buyRate,
    required double sellQty,
    required double sellRate,
    required double returnQty,
  }) async {
    final today = todayStr();
    final grnNo = await establishStockViaDirectGrn(verifier, refs, qty: buyQty, rate: buyRate);

    final sellGross = sellQty * sellRate;
    final orderNo = await verifier.rpc('fn_save_sales_order', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'order_no': null,
        'order_date': today,
        'order_mode': 'DIRECT',
        'customer_id': TestTenantConfig.customerId,
        'order_currency_id': refs.currencyId,
        'rate_to_base': 1,
        'rate_to_local': 1,
        'gross_amount': sellGross,
        'grand_total': sellGross,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': sellQty,
          'base_qty': sellQty,
          'rate': sellRate,
          'price_override_reason': 'QA scenario test - no Price Master row configured',
          'gross_amount': sellGross,
          'final_amount': sellGross,
          'base_amount': sellGross,
          'local_amount': sellGross,
        },
      ],
      'p_charges': [],
      'p_user_id': verifier.userId,
    }) as String;

    await verifier.rpc('fn_approve_sales_order', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_order_no': orderNo,
      'p_order_date': today,
      'p_approved_by': verifier.userId,
    });

    // AGAINST_ORDER: p_lines is ignored server-side (re-derived from the
    // order's own lines verbatim) — confirmed in 089_sales_invoice.sql.
    final invoiceNo = await verifier.rpc('fn_save_sales_invoice', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'invoice_no': null,
        'invoice_date': today,
        'invoice_mode': 'AGAINST_ORDER',
        'order_no': orderNo,
        'order_date': today,
        'sale_type': 'CREDIT',
        'invoice_currency_id': refs.currencyId,
        'rate_to_base': 1,
        'rate_to_local': 1,
        'gross_amount': sellGross,
        'grand_total': sellGross,
      },
      'p_lines': [],
      'p_charges': [],
      'p_batches': [],
      'p_serials': [],
      'p_user_id': verifier.userId,
      'p_credit_invoice_screen': true,
    }) as String;

    await verifier.rpc('fn_approve_sales_invoice', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_invoice_no': invoiceNo,
      'p_invoice_date': today,
      'p_approved_by': verifier.userId,
    });

    final deliveryNo = await verifier.rpc('fn_save_sales_delivery', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'delivery_no': null,
        'delivery_date': today,
        'invoice_no': invoiceNo,
        'invoice_date': today,
        'received_by_name': 'QA Scenario Test',
      },
      'p_lines': [
        {
          'serial_no': 1,
          'invoice_line_serial': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': sellQty,
          'base_qty': sellQty,
        },
      ],
      'p_batches': [],
      'p_serials': [],
      'p_transport': null,
      'p_user_id': verifier.userId,
    }) as String;

    await verifier.rpc('fn_approve_sales_delivery', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_delivery_no': deliveryNo,
      'p_delivery_date': today,
      'p_approved_by': verifier.userId,
    });

    final returnGross = returnQty * sellRate;
    final returnNo = await verifier.rpc('fn_save_sales_return', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'return_no': null,
        'return_date': today,
        'invoice_no': invoiceNo,
        'invoice_date': today,
        'taxable_amount': returnGross,
        'tax_amount': 0,
        'charges_amount': 0,
        'return_total': returnGross,
        'refund_amount_local': 0,
        'refund_amount_base': 0,
        'reason': 'QA scenario test return',
      },
      'p_lines': [
        {
          'serial_no': 1,
          'invoice_line_serial': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': returnQty,
          'base_qty': returnQty,
          'rate': sellRate,
          'gross_amount': returnGross,
          'tax_amount': 0,
          'final_amount': returnGross,
        },
      ],
      'p_batches': [],
      'p_serials': [],
      'p_charges': [],
      'p_user_id': verifier.userId,
    }) as String;

    await verifier.rpc('fn_approve_sales_return', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_return_no': returnNo,
      'p_return_date': today,
      'p_approved_by': verifier.userId,
    });

    // Collect the net balance (sellGross - returnGross) in local currency.
    final netDue = sellGross - returnGross;
    final pendingBill = await verifier.getOne(
      'rid_finance_lines',
      {
        'account_id': 'eq.${TestTenantConfig.customerId}',
        'trans_nature': 'eq.DR',
        'inv_bill_no': 'not.is.null',
      },
      select: 'inv_bill_no,inv_bill_date,trans_currency',
    );

    final receiptNo = await verifier.rpc('fn_save_cash_receipt', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'receipt_no': null,
        'receipt_date': today,
        'customer_id': TestTenantConfig.customerId,
        'local_amount': netDue,
        'base_amount': 0,
        'remarks': 'QA scenario test',
      },
      'p_lines': [
        {
          'inv_bill_no': pendingBill['inv_bill_no'],
          'inv_bill_date': pendingBill['inv_bill_date'],
          'bill_currency': pendingBill['trans_currency'],
          'applied_amount_local': netDue,
        },
      ],
      'p_user_id': verifier.userId,
    }) as String;

    await verifier.rpc('fn_approve_cash_receipt', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_receipt_no': receiptNo,
      'p_receipt_date': today,
      'p_approved_by': verifier.userId,
    });

    return OrderToCashResult(
      grnNo: grnNo,
      orderNo: orderNo,
      invoiceNo: invoiceNo,
      deliveryNo: deliveryNo,
      returnNo: returnNo,
      receiptNo: receiptNo,
      buyQty: buyQty,
      buyRate: buyRate,
      sellQty: sellQty,
      sellRate: sellRate,
      returnQty: returnQty,
      date: today,
    );
  }
}

class PurchaseToPayResult {
  final String orderNo, grnNo, invoiceNo, paymentTransNo, date;
  final double qty, rate, amount;
  PurchaseToPayResult({
    required this.orderNo,
    required this.grnNo,
    required this.invoiceNo,
    required this.paymentTransNo,
    required this.qty,
    required this.rate,
    required this.amount,
    required this.date,
  });
}

class OrderToCashResult {
  final String grnNo, orderNo, invoiceNo, deliveryNo, returnNo, receiptNo, date;
  final double buyQty, buyRate, sellQty, sellRate, returnQty;
  OrderToCashResult({
    required this.grnNo,
    required this.orderNo,
    required this.invoiceNo,
    required this.deliveryNo,
    required this.returnNo,
    required this.receiptNo,
    required this.buyQty,
    required this.buyRate,
    required this.sellQty,
    required this.sellRate,
    required this.returnQty,
    required this.date,
  });

  double get soldNetQty => sellQty - returnQty;
  double get remainingStockQty => buyQty - soldNetQty;
  double get netRevenue => (sellQty - returnQty) * sellRate;
  double get netCogs => (sellQty - returnQty) * buyRate;
}
