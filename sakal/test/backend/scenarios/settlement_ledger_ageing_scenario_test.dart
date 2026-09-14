import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

import 'scenario_helpers.dart';

/// Business scenario 8: Payment/Receipt settlement + Customer/Supplier
/// Ledger + Trial Balance + Pending Bills + Ageing — the deepest
/// cross-report reconciliation scenario. Deliberately does BOTH a customer
/// (against-bill) receipt AND a supplier (on-account) payment, so the
/// contrast between the two settlement conventions shows up within one
/// file:
///   - Customer side (against-bill): v_pending_bills AND ageing's own
///     total_outstanding both correctly track the partial settlement.
///   - Supplier side (on-account): v_pending_bills/ageing's
///     total_outstanding stay STALE (by design — an on-account payment
///     isn't tied to any specific bill, see purchase_to_pay_scenario_test.
///     dart's own doc comment) — but ageing's OWN `net_closing` field
///     (`total_outstanding - unsettled_advance`, 137_party_ageing_reports.
///     sql) DOES correctly net it, since the payment lands in that
///     function's separate "unsettled advance" bucket instead.
///
/// Numbers: Sales Invoice $500 to customer (10 @ $50, DIRECT/IMMEDIATE),
/// collect $300 against-bill (leaving $200). Purchase Invoice $400 from
/// supplier (8 @ $50 via PO+GRN), pay $150 on-account (leaving $250 by the
/// ledger, but $400 by the stale bill-tracking view).
void main() {
  late BackendVerifier verifier;
  late CommonRefs refs;
  late String cashAccountId;

  setUpAll(() async {
    verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);
    refs = await CommonRefs.load(verifier);
    await CommonRefs.ensureApprovePermission(verifier, 'SL-RCP');
    await CommonRefs.ensureQuickInvoiceSetup(verifier);
    await CommonRefs.ensureExchangeGainLossAccountLink(verifier);

    final cash = await verifier.getOne('rim_accounts', {'account_code': 'eq.1110001001'}, select: 'id');
    cashAccountId = cash['id'] as String;
  });

  test('Customer side: against-bill receipt correctly tracks in ledger, pending bills, and ageing', () async {
    final today = todayStr();

    await ScenarioHelpers.establishStockViaDirectGrn(verifier, refs, qty: 10, rate: 50);

    final invoiceNo = await verifier.rpc('fn_save_sales_invoice', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'invoice_no': null,
        'invoice_date': today,
        'invoice_mode': 'DIRECT',
        'sale_type': 'CREDIT',
        'customer_id': TestTenantConfig.customerId,
        'invoice_currency_id': refs.currencyId,
        'rate_to_base': 1,
        'rate_to_local': 1,
        'gross_amount': 500,
        'grand_total': 500,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': 10,
          'base_qty': 10,
          'rate': 50,
          'price_override_reason': 'QA scenario test - no Price Master row configured',
          'gross_amount': 500,
          'final_amount': 500,
          'base_amount': 500,
          'local_amount': 500,
        },
      ],
      'p_charges': [],
      'p_batches': [],
      'p_serials': [],
      'p_user_id': verifier.userId,
    }) as String;

    await verifier.rpc('fn_approve_sales_invoice', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_invoice_no': invoiceNo,
      'p_invoice_date': today,
      'p_approved_by': verifier.userId,
    });

    final ledgerAfterInvoice = await _ledger(verifier, TestTenantConfig.customerId, today);
    expect(ledgerAfterInvoice, closeTo(500, 0.01));

    final ageingAfterInvoice = await _customerAgeing(verifier, TestTenantConfig.customerId);
    expect((ageingAfterInvoice['total_outstanding'] as num).toDouble(), closeTo(500, 0.01));

    final pendingBillBeforeReceipt = await verifier.getOne(
      'v_pending_bills', {'account_id': 'eq.${TestTenantConfig.customerId}'}, select: 'balance_amount,settled_amount',
    );
    expect((pendingBillBeforeReceipt['balance_amount'] as num).toDouble(), closeTo(500, 0.01));

    final pendingBill = await verifier.getOne(
      'rid_finance_lines',
      {'account_id': 'eq.${TestTenantConfig.customerId}', 'trans_nature': 'eq.DR', 'inv_bill_no': 'not.is.null'},
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
        'local_amount': 300,
        'base_amount': 0,
        'remarks': 'QA scenario test',
      },
      'p_lines': [
        {
          'inv_bill_no': pendingBill['inv_bill_no'],
          'inv_bill_date': pendingBill['inv_bill_date'],
          'bill_currency': pendingBill['trans_currency'],
          'applied_amount_local': 300,
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

    final ledgerAfterReceipt = await _ledger(verifier, TestTenantConfig.customerId, today);
    expect(ledgerAfterReceipt, closeTo(200, 0.01), reason: '500 - 300 collected');

    final pendingBillAfterReceipt = await verifier.getOne(
      'v_pending_bills', {'account_id': 'eq.${TestTenantConfig.customerId}'}, select: 'balance_amount,settled_amount',
    );
    expect((pendingBillAfterReceipt['settled_amount'] as num).toDouble(), closeTo(300, 0.01));
    expect((pendingBillAfterReceipt['balance_amount'] as num).toDouble(), closeTo(200, 0.01),
        reason: 'Against-bill settlement correctly reduces v_pending_bills');

    final ageingAfterReceipt = await _customerAgeing(verifier, TestTenantConfig.customerId);
    expect((ageingAfterReceipt['total_outstanding'] as num).toDouble(), closeTo(200, 0.01),
        reason: 'Against-bill settlement correctly reduces ageing\'s total_outstanding too — contrast with the supplier (on-account) test below');

    await ScenarioHelpers.assertTrialBalanceBalances(verifier, dateFrom: today, dateTo: today);
  });

  test('Supplier side: on-account payment nets correctly in ledger + ageing net_closing, but NOT total_outstanding', () async {
    final today = todayStr();

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
        'gross_amount': 400,
        'discount_amount': 0,
        'charges_amount': 0,
        'item_tax_amount': 0,
        'charge_tax_amount': 0,
        'grand_total': 400,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': 8,
          'qty_loose': 0,
          'base_qty': 8,
          'rate': 50,
          'gross_amount': 400,
          'discount_percent': 0,
          'discount_amount': 0,
          'tax_amount': 0,
          'final_amount': 400,
          'base_amount': 400,
          'local_amount': 400,
          'charge_amount': 0,
          'landed_amount': 400,
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

    final grnNo = await ScenarioHelpers.receiveGrnAgainstPo(
      verifier, refs, orderNo: orderNo, orderDate: today, qty: 8, rate: 50,
    );

    final invoiceNo = await verifier.rpc('fn_save_purchase_invoice', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'invoice_no': null,
        'invoice_date': today,
        'supplier_id': TestTenantConfig.supplierId,
        'supplier_invoice_no': 'QA-SCEN8-BILL',
        'supplier_invoice_date': today,
        'invoice_currency_id': refs.currencyId,
        'rate_to_base': 1,
        'rate_to_local': 1,
        'taxable_amount': 400,
        'tax_amount': 0,
        'invoice_total': 400,
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

    final ledgerAfterBill = await _ledger(verifier, TestTenantConfig.supplierId, today);
    expect(ledgerAfterBill, closeTo(400, 0.01));

    final ageingAfterBill = await _supplierAgeing(verifier, TestTenantConfig.supplierId);
    expect((ageingAfterBill['total_outstanding'] as num).toDouble(), closeTo(400, 0.01));
    expect((ageingAfterBill['net_closing'] as num).toDouble(), closeTo(400, 0.01));

    // Pay $150 ON-ACCOUNT — no inv_bill_no, is_on_account:true.
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
          'trans_amount': 150,
          'trans_currency': 'USD',
          'base_amount': 150,
          'base_rate': 1,
          'local_amount': 150,
          'local_rate': 1,
          'party_amount': 150,
          'party_currency': 'USD',
          'party_rate': 1,
        },
        {
          'serial_no': 2,
          'account_id': cashAccountId,
          'trans_nature': 'CR',
          'trans_amount': 150,
          'trans_currency': 'USD',
          'base_amount': 150,
          'base_rate': 1,
          'local_amount': 150,
          'local_rate': 1,
          'party_amount': 150,
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

    final ledgerAfterPayment = await _ledger(verifier, TestTenantConfig.supplierId, today);
    expect(ledgerAfterPayment, closeTo(250, 0.01), reason: '400 - 150 paid — the ledger is always correct');

    final ageingAfterPayment = await _supplierAgeing(verifier, TestTenantConfig.supplierId);
    expect((ageingAfterPayment['total_outstanding'] as num).toDouble(), closeTo(400, 0.01),
        reason: 'total_outstanding stays STALE — an on-account payment is never tied to a specific bill (confirmed by design, see purchase_to_pay_scenario_test.dart)');
    expect((ageingAfterPayment['net_closing'] as num).toDouble(), closeTo(250, 0.01),
        reason: 'net_closing = total_outstanding - unsettled_advance DOES correctly net the on-account payment — this contrast IS the scenario\'s own point');

    await ScenarioHelpers.assertTrialBalanceBalances(verifier, dateFrom: today, dateTo: today);
  });
}

Future<double> _ledger(BackendVerifier verifier, String accountId, String date) async {
  final result = await verifier.rpc('fn_account_ledger_totals', {
    'p_client_id': verifier.clientId,
    'p_company_id': verifier.companyId,
    'p_account_id': accountId,
    'p_date_from': date,
    'p_date_to': date,
    'p_currency_mode': 'BASE',
  });
  final row = (result as List).first as Map<String, dynamic>;
  return (row['running_balance'] as num).toDouble();
}

Future<Map<String, dynamic>> _customerAgeing(BackendVerifier verifier, String accountId) async {
  final result = await verifier.rpc('fn_customer_ageing_lines', {
    'p_client_id': verifier.clientId,
    'p_company_id': verifier.companyId,
    'p_account_id': accountId,
  });
  return (result as List).first as Map<String, dynamic>;
}

Future<Map<String, dynamic>> _supplierAgeing(BackendVerifier verifier, String accountId) async {
  final result = await verifier.rpc('fn_supplier_ageing_lines', {
    'p_client_id': verifier.clientId,
    'p_company_id': verifier.companyId,
    'p_account_id': accountId,
  });
  return (result as List).first as Map<String, dynamic>;
}
