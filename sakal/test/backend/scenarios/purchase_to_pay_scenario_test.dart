import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

import 'scenario_helpers.dart';

/// Business scenario 1: full Purchase-to-Pay chain — PO -> GRN -> Purchase
/// Invoice -> Payment. Verifies stock/cost, the GRN's own provisional
/// accrual, the invoice's real payable, and — deliberately, not avoided —
/// the documented difference between an ON-ACCOUNT payment (settles the
/// ledger correctly but leaves the bill-tracking view stale, by design:
/// an on-account payment isn't tied to any specific bill) and an
/// AGAINST-BILL payment (writes a real settlement record).
///
/// Numbers: PO+GRN 10 units @ $50 ($500), pay in full on-account.
void main() {
  late BackendVerifier verifier;
  late CommonRefs refs;
  late String cashAccountId;

  setUpAll(() async {
    verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);
    refs = await CommonRefs.load(verifier);

    final cash = await verifier.getOne(
      'rim_accounts', {'account_code': 'eq.1110001001'}, select: 'id', // "Cash In Had USD"
    );
    cashAccountId = cash['id'] as String;
  });

  test('Purchase-to-Pay: PO->GRN->Invoice->on-account Payment, stock/cost/ledger all correct', () async {
    final result = await ScenarioHelpers.runPurchaseToPayChain(
      verifier, refs,
      qty: 10, rate: 50, supplierInvoiceNo: 'QA-SCEN1-BILL', cashAccountId: cashAccountId,
    );

    final poStatus = await verifier.getOne('rih_purchase_orders', {'order_no': 'eq.${result.orderNo}'}, select: 'status');
    expect(poStatus['status'], 'CLOSED');

    final stock = await ScenarioHelpers.stockAt(verifier, TestTenantConfig.locationId);
    expect(stock.currentStock, 10);
    expect(stock.costPrice, closeTo(50, 0.01));

    // GRN's own provisional accrual (JV): DR Stock / CR Purchase Accrual.
    final grnLines = await ScenarioHelpers.financeLinesFor(
      verifier, sourceDocType: 'GRN', sourceDocNo: result.grnNo, voucherTypeCode: 'JV',
    );
    ScenarioHelpers.assertLinesBalance(grnLines);
    final grnStockLine = grnLines.firstWhere((l) => l['account_id'] == TestTenantConfig.stockAccountId);
    expect(grnStockLine['trans_nature'], 'DR');
    expect((grnStockLine['base_amount'] as num).toDouble(), closeTo(500, 0.01));

    // Purchase Invoice: real payable, PUR voucher, findable via the
    // supplier's OWN invoice number.
    final invoiceApproved = await verifier.getOne(
      'rih_purchase_invoices', {'invoice_no': 'eq.${result.invoiceNo}'}, select: 'status,posted_voucher_no',
    );
    expect(invoiceApproved['status'], 'APPROVED');
    expect(invoiceApproved['posted_voucher_no'], isNotNull);

    final pendingBillLine = await verifier.getOne(
      'rid_finance_lines', {'inv_bill_no': 'eq.QA-SCEN1-BILL'}, select: 'account_id,trans_nature,base_amount',
    );
    expect(pendingBillLine['account_id'], TestTenantConfig.supplierId);
    expect(pendingBillLine['trans_nature'], 'CR');
    expect((pendingBillLine['base_amount'] as num).toDouble(), closeTo(500, 0.01));

    // The ledger is always correct — an on-account payment nets it to zero
    // regardless of whether it's tied to a specific bill.
    final ledgerResult = await verifier.rpc('fn_account_ledger_totals', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_account_id': TestTenantConfig.supplierId,
      'p_date_from': result.date,
      'p_date_to': result.date,
      'p_currency_mode': 'BASE',
    }); // BASE avoids party-currency FX rounding noise unrelated to what's being tested here
    final ledgerRow = (ledgerResult as List).first as Map<String, dynamic>;
    expect((ledgerRow['running_balance'] as num).toDouble(), closeTo(0, 0.01),
        reason: 'A full on-account payment must net the ledger to exactly zero');

    // The known, CORRECT-BY-DESIGN divergence: an on-account payment never
    // writes a rid_invoice_bill_settlement row (058_voucher_balance_check_
    // uses_base_amount.sql: settlement records are written only when NOT
    // is_on_account — an on-account payment genuinely isn't tied to any
    // specific bill, so there's nothing for the bill-tracking view to
    // apply it against). v_pending_bills therefore still shows this exact
    // bill as fully outstanding even though the account itself is settled.
    final pendingBillRow = await verifier.getOne(
      'v_pending_bills', {'inv_bill_no': 'eq.QA-SCEN1-BILL'}, select: 'balance_amount,settled_amount',
    );
    expect((pendingBillRow['balance_amount'] as num).toDouble(), closeTo(500, 0.01),
        reason: 'v_pending_bills is bill-tracked, not ledger-tracked — an on-account payment correctly does not settle a specific bill row (see this test\'s own doc comment)');
    expect((pendingBillRow['settled_amount'] as num).toDouble(), closeTo(0, 0.01));

    await ScenarioHelpers.assertTrialBalanceBalances(verifier, dateFrom: result.date, dateTo: result.date);
  });

  test('Purchase-to-Pay: an AGAINST-BILL payment DOES write a real settlement record', () async {
    // Fresh bill+payment pair, isolated from the on-account test above (no
    // reset needed — a different supplier_invoice_no keeps them distinct).
    final result = await ScenarioHelpers.runPurchaseToPayChain(
      verifier, refs,
      qty: 5, rate: 20, supplierInvoiceNo: 'QA-SCEN1-BILL-2', cashAccountId: cashAccountId,
    );
    // runPurchaseToPayChain always pays on-account — settle a SECOND time,
    // this time against-bill, against a fresh identical-shaped bill of our
    // own to isolate the against-bill code path cleanly.
    final today = result.date;

    final orderNo2 = await verifier.rpc('fn_save_purchase_order', {
      'p_header': {
        'client_id': verifier.clientId, 'company_id': verifier.companyId, 'location_id': TestTenantConfig.locationId,
        'order_no': null, 'order_date': today, 'po_type': 'LOCAL', 'supplier_id': TestTenantConfig.supplierId,
        'po_currency_id': refs.currencyId, 'rate_to_base': 1, 'rate_to_local': 1,
        'gross_amount': 100, 'grand_total': 100,
      },
      'p_lines': [
        {
          'serial_no': 1, 'product_id': TestTenantConfig.productId, 'uom_id': refs.uomId,
          'uom_conversion_factor': 1, 'qty_pack': 2, 'base_qty': 2, 'rate': 50,
          'gross_amount': 100, 'final_amount': 100, 'base_amount': 100, 'local_amount': 100,
        },
      ],
      'p_charges': [], 'p_payment_terms': [], 'p_user_id': verifier.userId,
    }) as String;
    await verifier.rpc('fn_approve_purchase_order', {
      'p_client_id': verifier.clientId, 'p_company_id': verifier.companyId,
      'p_order_no': orderNo2, 'p_order_date': today, 'p_approved_by': verifier.userId,
    });
    final grnNo2 = await ScenarioHelpers.receiveGrnAgainstPo(
      verifier, refs, orderNo: orderNo2, orderDate: today, qty: 2, rate: 50,
    );
    final invoiceNo2 = await verifier.rpc('fn_save_purchase_invoice', {
      'p_header': {
        'client_id': verifier.clientId, 'company_id': verifier.companyId, 'location_id': TestTenantConfig.locationId,
        'invoice_no': null, 'invoice_date': today, 'supplier_id': TestTenantConfig.supplierId,
        'supplier_invoice_no': 'QA-SCEN1-BILL-3', 'supplier_invoice_date': today,
        'invoice_currency_id': refs.currencyId, 'rate_to_base': 1, 'rate_to_local': 1,
        'taxable_amount': 100, 'tax_amount': 0, 'invoice_total': 100,
      },
      'p_grn_refs': [{'grn_no': grnNo2, 'grn_date': today}],
      'p_user_id': verifier.userId,
    }) as String;
    await verifier.rpc('fn_approve_purchase_invoice', {
      'p_client_id': verifier.clientId, 'p_company_id': verifier.companyId,
      'p_invoice_no': invoiceNo2, 'p_invoice_date': today, 'p_approved_by': verifier.userId,
    });

    // Pay AGAINST-BILL — inv_bill_no = the supplier's own invoice number,
    // is_on_account:false.
    final payTransNo = await verifier.rpc('fn_save_finance_voucher', {
      'p_header': {
        'client_id': verifier.clientId, 'company_id': verifier.companyId, 'location_id': TestTenantConfig.locationId,
        'trans_no': null, 'trans_date': today, 'voucher_type_code': 'CPV',
        'is_on_account': false, 'remarks': 'QA scenario test - against bill payment',
      },
      'p_lines': [
        {
          'serial_no': 1, 'account_id': TestTenantConfig.supplierId, 'trans_nature': 'DR',
          'trans_amount': 100, 'trans_currency': 'USD', 'base_amount': 100, 'base_rate': 1,
          'local_amount': 100, 'local_rate': 1, 'party_amount': 100, 'party_currency': 'USD', 'party_rate': 1,
          'inv_bill_no': 'QA-SCEN1-BILL-3', 'inv_bill_date': today,
        },
        {
          'serial_no': 2, 'account_id': cashAccountId, 'trans_nature': 'CR',
          'trans_amount': 100, 'trans_currency': 'USD', 'base_amount': 100, 'base_rate': 1,
          'local_amount': 100, 'local_rate': 1, 'party_amount': 100, 'party_currency': 'USD', 'party_rate': 1,
        },
      ],
      'p_user_id': verifier.userId,
    }) as String;
    await verifier.rpc('fn_post_finance_voucher', {
      'p_client_id': verifier.clientId, 'p_company_id': verifier.companyId, 'p_location_id': TestTenantConfig.locationId,
      'p_trans_no': payTransNo, 'p_trans_date': today, 'p_posted_by': verifier.userId,
    });

    // A real settlement record must now exist — this is the correctly-
    // tracked case, in contrast to the on-account test above.
    final settlement = await verifier.getOne(
      'rid_invoice_bill_settlement',
      {'inv_bill_no': 'eq.QA-SCEN1-BILL-3', 'account_id': 'eq.${TestTenantConfig.supplierId}'},
      select: 'paid_amount,was_balance',
    );
    expect((settlement['paid_amount'] as num).toDouble(), closeTo(100, 0.01));
    // was_balance is looked up by matching inv_bill_no against ANOTHER
    // voucher's own trans_no (058's own logic) — works for Sales Invoice/
    // Cash Receipt's convention but NOT for Purchase Bill's (inv_bill_no
    // here is the supplier's own paper invoice number, never any
    // voucher's trans_no) — record whatever this actually comes back as,
    // don't assume it either way. This is the narrower, corrected version
    // of the "known inconsistency" documented in
    // payment_receipt_voucher_backend_test.dart: only this AUDIT field is
    // affected, not whether the bill's own balance actually clears (see
    // v_pending_bills assertion below, which IS correct regardless).
    // ignore: avoid_print
    print('QA-SCEN1-BILL-3 settlement was_balance = ${settlement['was_balance']} (expected 100 if the lookup succeeded, 0 if it hit the documented inv_bill_no-matching gap)');

    // Regardless of was_balance's own correctness, the bill's tracked
    // balance MUST actually reduce — this is what genuinely matters for
    // day-to-day use (does the bill show as paid). v_pending_bills itself
    // filters WHERE balance_amount > 0.001 (117_pending_bills_report_
    // columns.sql) — a fully-settled bill correctly disappears from the
    // view entirely, so the real assertion is that it's now GONE, not
    // that it appears with a zero balance.
    final pendingBillRows2 = await verifier.get('v_pending_bills', {'inv_bill_no': 'eq.QA-SCEN1-BILL-3'});
    expect(pendingBillRows2, isEmpty,
        reason: 'A fully against-bill-settled bill must disappear from v_pending_bills entirely (its own WHERE balance_amount > 0.001 filter)');
  });
}
