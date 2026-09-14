import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

import 'scenario_helpers.dart';

/// Business scenario 4: PO -> GRN -> Purchase Invoice -> Purchase Return,
/// against a BILLED GRN — verifies the return posts a real Supplier Debit
/// Note (SDN) reversing the actual payable, not the provisional JV
/// accrual (that's scenario 3, the unbilled mirror-image). The QA
/// fixture's own test product has NO tax_group_id configured at all
/// (confirmed via backend/scripts/seed_qa_master_data.sql) — this return
/// is genuinely zero-tax, so only Stock+Supplier lines are expected, no
/// VAT-reversal lines.
///
/// Numbers: PO+GRN 10 units @ $50 ($500), bill it, return 4 units ($200)
/// at the same $50/unit rate — keeping the return amount an exact multiple
/// of the GRN's own rate avoids any rounding plug against
/// PURCHASE_RETURNS_ACCOUNT (061_purchase_return.sql: only fires when
/// abs(plug) > 0.0001), so no extra account-link setup is needed here.
void main() {
  late BackendVerifier verifier;
  late CommonRefs refs;

  setUpAll(() async {
    verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);
    refs = await CommonRefs.load(verifier);
  });

  test('Purchase Return (billed GRN): posts a real Supplier Debit Note, no JV', () async {
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

    final invoiceNo = await verifier.rpc('fn_save_purchase_invoice', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'invoice_no': null,
        'invoice_date': today,
        'supplier_id': TestTenantConfig.supplierId,
        'supplier_invoice_no': 'QA-SCEN4-BILL',
        'supplier_invoice_date': today,
        'invoice_currency_id': refs.currencyId,
        'rate_to_base': 1,
        'rate_to_local': 1,
        'taxable_amount': 500,
        'tax_amount': 0,
        'invoice_total': 500,
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

    final grnAfterBill = await verifier.getOne(
      'rih_grn_headers', {'grn_no': 'eq.$grnNo'}, select: 'billed_invoice_no',
    );
    expect(grnAfterBill['billed_invoice_no'], invoiceNo, reason: 'Precondition: this GRN must now be billed');

    final supplierLedgerAfterBill = await verifier.rpc('fn_account_ledger_totals', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_account_id': TestTenantConfig.supplierId,
      'p_date_from': today,
      'p_date_to': today,
      'p_currency_mode': 'BASE',
    }); // BASE avoids party-currency FX rounding noise unrelated to what's being tested here
    final afterBillRow = (supplierLedgerAfterBill as List).first as Map<String, dynamic>;
    expect((afterBillRow['running_balance'] as num).toDouble(), closeTo(500, 0.01));
    expect(afterBillRow['running_balance_type'], 'Cr');

    // ── Return 4 of the 10 units, same $50/unit rate as the GRN ─────────
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
        'reason': 'QA scenario test - billed return',
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

    final stock = await ScenarioHelpers.stockAt(verifier, TestTenantConfig.locationId);
    expect(stock.currentStock, 6, reason: '10 - 4 returned');

    // The billed path: a real Supplier Debit Note, DR Supplier / CR Stock,
    // zero VAT lines (fixture product is untaxed) — and explicitly NO JV.
    final sdnLines = await ScenarioHelpers.financeLinesFor(
      verifier, sourceDocType: 'PURCHASE_RETURN', sourceDocNo: returnNo, voucherTypeCode: 'SDN',
    );
    expect(sdnLines, isNotEmpty, reason: 'A BILLED return must post a real Supplier Debit Note');
    ScenarioHelpers.assertLinesBalance(sdnLines);

    final supplierDrLine = sdnLines.firstWhere((l) => l['account_id'] == TestTenantConfig.supplierId);
    expect(supplierDrLine['trans_nature'], 'DR');
    expect((supplierDrLine['base_amount'] as num).toDouble(), closeTo(200, 0.01));

    final stockCrLine = sdnLines.firstWhere((l) => l['account_id'] == TestTenantConfig.stockAccountId);
    expect(stockCrLine['trans_nature'], 'CR');
    expect((stockCrLine['base_amount'] as num).toDouble(), closeTo(200, 0.01));

    final jvLines = await ScenarioHelpers.financeLinesFor(
      verifier, sourceDocType: 'PURCHASE_RETURN', sourceDocNo: returnNo, voucherTypeCode: 'JV',
    );
    expect(jvLines, isEmpty, reason: 'A BILLED return must never post a provisional JV reversal — proves the billed code path fired, not the unbilled one');

    // Supplier ledger: 500 Cr (bill) - 200 (return) = 300 Cr.
    final supplierLedgerAfterReturn = await verifier.rpc('fn_account_ledger_totals', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_account_id': TestTenantConfig.supplierId,
      'p_date_from': today,
      'p_date_to': today,
      'p_currency_mode': 'BASE',
    }); // BASE avoids party-currency FX rounding noise unrelated to what's being tested here
    final afterReturnRow = (supplierLedgerAfterReturn as List).first as Map<String, dynamic>;
    expect((afterReturnRow['running_balance'] as num).toDouble(), closeTo(300, 0.01));
    expect(afterReturnRow['running_balance_type'], 'Cr');

    await ScenarioHelpers.assertTrialBalanceBalances(verifier, dateFrom: today, dateTo: today);
  });
}
