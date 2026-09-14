import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

import 'scenario_helpers.dart';

/// Business scenario 3: PO -> GRN -> Purchase Return, against an UNBILLED
/// GRN (no Purchase Invoice raised yet). Verifies the provisional JV
/// accrual is reversed correctly and that no SDN (Supplier Debit Note)
/// voucher exists — proving this is genuinely the unbilled code path, the
/// mirror-image scenario to purchase_return_billed_scenario_test.dart.
///
/// Numbers: PO+GRN 10 units @ $50 ($500 total), return 4 units ($200).
void main() {
  late BackendVerifier verifier;
  late CommonRefs refs;

  setUpAll(() async {
    verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);
    refs = await CommonRefs.load(verifier);
  });

  test('Purchase Return (unbilled GRN): reverses the provisional JV accrual, no SDN posted', () async {
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
        'gross_amount': 500,
        'discount_amount': 0,
        'charges_amount': 0,
        'item_tax_amount': 0,
        'charge_tax_amount': 0,
        'grand_total': 500,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': 10,
          'qty_loose': 0,
          'base_qty': 10,
          'rate': 50,
          'gross_amount': 500,
          'discount_percent': 0,
          'discount_amount': 0,
          'tax_amount': 0,
          'final_amount': 500,
          'base_amount': 500,
          'local_amount': 500,
          'charge_amount': 0,
          'landed_amount': 500,
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
      verifier, refs, orderNo: orderNo, orderDate: today, qty: 10, rate: 50,
    );

    var stock = await ScenarioHelpers.stockAt(verifier, TestTenantConfig.locationId);
    expect(stock.currentStock, 10);

    final poAfterGrn = await verifier.getOne(
      'rih_purchase_orders', {'order_no': 'eq.$orderNo'}, select: 'status',
    );
    expect(poAfterGrn['status'], 'CLOSED', reason: 'Fully received PO closes');

    final grnHeader = await verifier.getOne(
      'rih_grn_headers', {'grn_no': 'eq.$grnNo'}, select: 'billed_invoice_no',
    );
    expect(grnHeader['billed_invoice_no'], isNull, reason: 'Precondition: this GRN must be genuinely unbilled');

    // GRN's own provisional accrual — a JV, DR Stock / CR Purchase Accrual.
    final grnLines = await ScenarioHelpers.financeLinesFor(
      verifier, sourceDocType: 'GRN', sourceDocNo: grnNo, voucherTypeCode: 'JV',
    );
    ScenarioHelpers.assertLinesBalance(grnLines);
    final grnStockLine = grnLines.firstWhere((l) => l['account_id'] == TestTenantConfig.stockAccountId);
    expect(grnStockLine['trans_nature'], 'DR');
    expect((grnStockLine['base_amount'] as num).toDouble(), closeTo(500, 0.01));

    // ── Return 4 of the 10 units ─────────────────────────────────────────
    final returnNo = await verifier.rpc('fn_save_purchase_return', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'return_no': null,
        'return_date': today,
        'supplier_id': TestTenantConfig.supplierId,
        'return_currency_id': refs.currencyId,
        'rate_to_base': 1,
        'rate_to_local': 1,
        'taxable_amount': 200,
        'tax_amount': 0,
        'return_total': 200,
        'reason': 'QA scenario test - unbilled return',
      },
      'p_lines': [
        {
          'serial_no': 1,
          'source_grn_no': grnNo,
          'source_grn_date': today,
          'source_grn_line_serial': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': 4,
          'qty_loose': 0,
          'base_qty': 4,
          'rate': 50,
          'gross_amount': 200,
          'tax_amount': 0,
          'final_amount': 200,
        },
      ],
      'p_batches': [],
      'p_serials': [],
      'p_charges': [],
      'p_user_id': verifier.userId,
    }) as String;

    await verifier.rpc('fn_approve_purchase_return', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_return_no': returnNo,
      'p_return_date': today,
      'p_reopen_po': false,
      'p_approved_by': verifier.userId,
    });

    stock = await ScenarioHelpers.stockAt(verifier, TestTenantConfig.locationId);
    expect(stock.currentStock, 6, reason: '10 - 4 returned');

    // PO qty_received always rolls back regardless of p_reopen_po.
    final poLine = await verifier.getOne(
      'rid_purchase_order_lines',
      {'order_no': 'eq.$orderNo', 'order_date': 'eq.$today', 'serial_no': 'eq.1'},
      select: 'qty_received',
    );
    expect((poLine['qty_received'] as num).toDouble(), 6, reason: '10 received - 4 returned');

    // The unbilled reversal: DR PURCHASE_ACCRUAL_ACCOUNT / CR STOCK_ACCOUNT,
    // tax-exclusive, posted as a JV — and explicitly NO SDN voucher exists.
    final reversalLines = await ScenarioHelpers.financeLinesFor(
      verifier, sourceDocType: 'PURCHASE_RETURN', sourceDocNo: returnNo, voucherTypeCode: 'JV',
    );
    expect(reversalLines, isNotEmpty, reason: 'The unbilled path must post a JV reversal');
    ScenarioHelpers.assertLinesBalance(reversalLines);
    final returnStockLine = reversalLines.firstWhere((l) => l['account_id'] == TestTenantConfig.stockAccountId);
    expect(returnStockLine['trans_nature'], 'CR');
    expect((returnStockLine['base_amount'] as num).toDouble(), closeTo(200, 0.01));

    final sdnLines = await ScenarioHelpers.financeLinesFor(
      verifier, sourceDocType: 'PURCHASE_RETURN', sourceDocNo: returnNo, voucherTypeCode: 'SDN',
    );
    expect(sdnLines, isEmpty, reason: 'An UNBILLED return must never post a Supplier Debit Note — proves the unbilled code path fired, not the billed one');

    await ScenarioHelpers.assertTrialBalanceBalances(verifier, dateFrom: today, dateTo: today);
  });
}
