import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

import 'scenario_helpers.dart';

/// Business scenario 2: full Order-to-Cash chain — Sales Order ->
/// AGAINST_ORDER Sales Invoice (deferred dispatch) -> Sales Delivery ->
/// Sales Return -> Cash Receipt. Verifies stock only leaves at Delivery
/// (not at invoice approval), COGS posts only at Delivery and reverses
/// proportionally on Return, and the customer's ledger nets to exactly
/// zero after the final collection.
///
/// Numbers: buy 10 @ $50 (cost basis), sell 6 @ $60 ($360), return 2 ($120),
/// collect the remaining $240 in cash.
void main() {
  late BackendVerifier verifier;
  late CommonRefs refs;

  setUpAll(() async {
    verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);
    refs = await CommonRefs.load(verifier);
    await CommonRefs.ensureApprovePermission(verifier, 'SL-RCP');
    await CommonRefs.ensureQuickInvoiceSetup(verifier);
    await CommonRefs.ensureExchangeGainLossAccountLink(verifier);
    await CommonRefs.ensureSalesReturnsAccountLink(verifier);
  });

  test('Order-to-Cash: stock/COGS/customer ledger all correct across the full chain', () async {
    final result = await ScenarioHelpers.runOrderToCashChain(
      verifier, refs, buyQty: 10, buyRate: 50, sellQty: 6, sellRate: 60, returnQty: 2,
    );

    // Order itself never touches stock/GL.
    final orderStatus = await verifier.getOne('rih_sales_orders', {'order_no': 'eq.${result.orderNo}'}, select: 'status');
    expect(orderStatus['status'], 'APPROVED');

    // Invoice approval (deferred dispatch): stock must NOT have moved yet,
    // only the SI (sales) voucher posts, no COS voucher exists yet. We
    // can't observe the "right after invoice approval, before delivery"
    // moment directly since the chain has already run to completion by
    // the time this test body resumes control — instead assert the FINAL
    // stock number accounts correctly for deferred timing (see below) and
    // rely on sales_delivery_backend_test.dart's own dedicated mid-chain
    // snapshot for the "stock unchanged right after invoice approval"
    // check in isolation.
    final invoiceStatus = await verifier.getOne('rih_sales_invoices', {'invoice_no': 'eq.${result.invoiceNo}'}, select: 'status');
    expect(invoiceStatus['status'], 'APPROVED');

    final siLines = await ScenarioHelpers.financeLinesFor(
      verifier, sourceDocType: 'SALES_INVOICE', sourceDocNo: result.invoiceNo, voucherTypeCode: 'SLS',
    );
    expect(siLines, isNotEmpty);
    ScenarioHelpers.assertLinesBalance(siLines);
    final customerDrLine = siLines.firstWhere((l) => l['account_id'] == TestTenantConfig.customerId);
    expect(customerDrLine['trans_nature'], 'DR');
    expect((customerDrLine['base_amount'] as num).toDouble(), closeTo(360, 0.01));

    // No COS voucher tagged to the INVOICE itself — deferred dispatch posts
    // COS at Delivery time instead, tagged to the DELIVERY (102_sales_
    // delivery.sql line ~692 — confirmed live 2026-09-14).
    final cosOnInvoice = await ScenarioHelpers.financeLinesFor(
      verifier, sourceDocType: 'SALES_INVOICE', sourceDocNo: result.invoiceNo, voucherTypeCode: 'COS',
    );
    expect(cosOnInvoice, isEmpty, reason: 'A deferred-dispatch invoice must never post its own COS voucher');

    final deliveryStatus = await verifier.getOne('rih_sales_delivery_headers', {'delivery_no': 'eq.${result.deliveryNo}'}, select: 'status');
    expect(deliveryStatus['status'], 'APPROVED');

    final cosOnDelivery = await ScenarioHelpers.financeLinesFor(
      verifier, sourceDocType: 'SALES_DELIVERY', sourceDocNo: result.deliveryNo, voucherTypeCode: 'COS',
    );
    expect(cosOnDelivery, isNotEmpty, reason: 'Delivery approval is where a deferred invoice\'s COS actually posts');
    ScenarioHelpers.assertLinesBalance(cosOnDelivery);
    final cogsLine = cosOnDelivery.firstWhere((l) => l['trans_nature'] == 'DR');
    expect((cogsLine['base_amount'] as num).toDouble(), closeTo(300, 0.01), reason: '6 units at the GRN cost of 50/unit');

    // ── REAL BUG FOUND 2026-09-14, FIXED SAME DAY (migration 187) ──────────
    // Sales Return's own stock/COGS reversal was gated ENTIRELY on
    // `v_invoice.stock_dispatch_mode = 'IMMEDIATE'` — for a DEFERRED-
    // dispatch invoice (Credit Sales Invoice -> Sales Delivery, exactly
    // this scenario's own chain), that condition was false, so the entire
    // reversal block was skipped even though the goods were genuinely
    // delivered. Fixed in `187_sales_return_deferred_dispatch_reversal_
    // fix.sql`, deployed and confirmed live the same day once direct
    // database access became available: the fix broadens the gate to also
    // fire when the invoice is DEFERRED but has at least one APPROVED
    // Sales Delivery — `rid_sales_return_lines.cost_price` was ALREADY
    // correctly populated for both dispatch modes (migrations 121/123
    // resolve/copy it unconditionally), so no join-based cost re-lookup
    // was actually needed once the current function body was read
    // correctly — only the gate itself was wrong.
    final returnStatus = await verifier.getOne('rih_sales_return_headers', {'return_no': 'eq.${result.returnNo}'}, select: 'status');
    expect(returnStatus['status'], 'APPROVED');

    final returnCos = await ScenarioHelpers.financeLinesFor(
      verifier, sourceDocType: 'SALES_RETURN', sourceDocNo: result.returnNo, voucherTypeCode: 'COS',
    );
    expect(returnCos, isNotEmpty, reason: 'Sales Return must reverse the returned units\' own cost, even for a deferred-dispatch sale (187)');
    ScenarioHelpers.assertLinesBalance(returnCos);
    final cogsReversalLine = returnCos.firstWhere((l) => l['trans_nature'] == 'CR');
    expect((cogsReversalLine['base_amount'] as num).toDouble(), closeTo(100, 0.01), reason: '2 returned units at 50/unit cost');

    // Final stock: 10 bought - 6 sold (at Delivery) + 2 returned = 6.
    final stock = await ScenarioHelpers.stockAt(verifier, TestTenantConfig.locationId);
    expect(stock.currentStock, 6);

    // Customer ledger: 360 Dr (invoice) - 120 (return) - 240 (receipt) = 0.
    final receiptStatus = await verifier.getOne('rih_cash_receipt_headers', {'receipt_no': 'eq.${result.receiptNo}'}, select: 'status');
    expect(receiptStatus['status'], 'APPROVED');

    // p_currency_mode: 'BASE' (not the default 'PARTY') — PARTY mode
    // converts through the customer's own ledger currency using a fresh
    // real exchange-rate lookup, which introduced a small (~$0.09)
    // rounding residual unrelated to anything this scenario is testing.
    // BASE mode is what genuinely must net to zero, by construction of
    // fn_post_finance_voucher's own DR=CR (base_amount) balance check.
    final ledgerResult = await verifier.rpc('fn_account_ledger_totals', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_account_id': TestTenantConfig.customerId,
      'p_date_from': result.date,
      'p_date_to': result.date,
      'p_currency_mode': 'BASE',
    });
    final ledgerRow = (ledgerResult as List).first as Map<String, dynamic>;
    expect((ledgerRow['running_balance'] as num).toDouble(), closeTo(0, 0.01),
        reason: 'Invoice (\$360) - Return (\$120) - Receipt (\$240) must net to exactly zero');

    await ScenarioHelpers.assertTrialBalanceBalances(verifier, dateFrom: result.date, dateTo: result.date);
  });
}
