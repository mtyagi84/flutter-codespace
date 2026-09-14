import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

import 'scenario_helpers.dart';

/// Business scenario (Phase A, edge case #1): full lifecycle of a
/// BATCH-tracked product — GRN with a real batch number -> Sales Invoice
/// allocating that specific batch -> Sales Return re-selecting it back.
/// Every other scenario in this suite uses TestTenantConfig.productId,
/// which is untracked (`tracking_type='NONE'`) — this is the first
/// end-to-end proof that the batch-allocation plumbing itself (not just
/// aggregate quantities) works across a full document chain, and that
/// the "batch/serial can NEVER go negative, regardless of allow_negative_
/// stock flags" rule (CLAUDE.md) actually holds live.
///
/// Numbers: GRN 10 units of a fresh product into batch "BATCH-001" @ $50,
/// sell 6 from that batch, return 2 back into it.
void main() {
  late BackendVerifier verifier;
  late CommonRefs refs;
  late String batchProductId;

  setUpAll(() async {
    verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);
    refs = await CommonRefs.load(verifier);
    await CommonRefs.ensureSalesReturnsAccountLink(verifier);
    batchProductId = await ScenarioHelpers.ensureBatchTrackedProduct(verifier, refs);
  });

  test('Batch-tracked product: GRN -> allocate on sale -> re-allocate on return', () async {
    final today = todayStr();
    const batchNo = 'BATCH-001';

    // ── GRN: receive 10 units into a real batch ─────────────────────────
    final grnNo = await verifier.rpc('fn_save_grn', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'grn_no': null,
        'grn_date': today,
        'supplier_id': TestTenantConfig.supplierId,
        'receipt_mode': 'DIRECT',
        'grn_currency_id': refs.currencyId,
        'rate_to_base': 1,
        'rate_to_local': 1,
        'gross_amount': 500,
        'grand_total': 500,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': batchProductId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': 10,
          'base_qty': 10,
          'rate': 50,
          'gross_amount': 500,
          'final_amount': 500,
          'base_amount': 500,
          'local_amount': 500,
        },
      ],
      'p_batches': [
        {'line_serial': 1, 'batch_no': batchNo, 'qty_pack': 10, 'qty_loose': 0, 'base_qty': 10},
      ],
      'p_serials': [],
      'p_charges': [],
      'p_user_id': verifier.userId,
    }) as String;

    await verifier.rpc('fn_approve_grn', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_grn_no': grnNo,
      'p_grn_date': today,
      'p_approved_by': verifier.userId,
    });

    var balance = await ScenarioHelpers.batchBalance(
      verifier, productId: batchProductId, locationId: TestTenantConfig.locationId, batchNo: batchNo,
    );
    expect(balance, 10, reason: 'GRN must post exactly 10 units into batch $batchNo');

    // ── Sales Invoice: sell 6, allocating THAT batch (mandatory for a
    // batch-tracked product on an immediate-dispatch sale) ─────────────
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
        'gross_amount': 360,
        'grand_total': 360,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': batchProductId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': 6,
          'base_qty': 6,
          'rate': 60,
          'price_override_reason': 'QA scenario test - no Price Master row configured',
          'gross_amount': 360,
          'final_amount': 360,
          'base_amount': 360,
          'local_amount': 360,
        },
      ],
      'p_charges': [],
      'p_batches': [
        {'line_serial': 1, 'batch_no': batchNo, 'base_qty': 6},
      ],
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

    balance = await ScenarioHelpers.batchBalance(
      verifier, productId: batchProductId, locationId: TestTenantConfig.locationId, batchNo: batchNo,
    );
    expect(balance, 4, reason: '10 received - 6 allocated from batch $batchNo');

    // ── Negative-batch-stock guard: batch/serial can NEVER go negative,
    // regardless of any allow_negative_stock flag (CLAUDE.md) — attempt
    // to sell more of this batch than remains (4) and confirm rejection.
    var threw = false;
    try {
      await verifier.rpc('fn_save_sales_invoice', {
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
          'gross_amount': 500,
          'grand_total': 500,
        },
        'p_lines': [
          {
            'serial_no': 1,
            'product_id': batchProductId,
            'uom_id': refs.uomId,
            'base_qty': 5,
            'rate': 50,
            'price_override_reason': 'QA scenario test',
            'final_amount': 500,
            'base_amount': 500,
            'local_amount': 500,
          },
        ],
        'p_charges': [],
        'p_batches': [
          {'line_serial': 1, 'batch_no': batchNo, 'base_qty': 5},
        ],
        'p_serials': [],
        'p_user_id': verifier.userId,
      }).then((invNo) => verifier.rpc('fn_approve_sales_invoice', {
            'p_client_id': verifier.clientId,
            'p_company_id': verifier.companyId,
            'p_invoice_no': invNo,
            'p_invoice_date': today,
            'p_approved_by': verifier.userId,
          }));
    } catch (_) {
      threw = true;
    }
    expect(threw, isTrue, reason: 'Selling 5 units from a batch with only 4 remaining must be rejected (BATCH_INSUFFICIENT_STOCK) even though this is a fresh, unrelated invoice');

    // ── Sales Return: return 2, re-selecting the same batch ─────────────
    final returnNo = await verifier.rpc('fn_save_sales_return', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'return_no': null,
        'return_date': today,
        'invoice_no': invoiceNo,
        'invoice_date': today,
        'taxable_amount': 120,
        'tax_amount': 0,
        'charges_amount': 0,
        'return_total': 120,
        'refund_amount_local': 0,
        'refund_amount_base': 0,
        'reason': 'QA scenario test return',
      },
      'p_lines': [
        {
          'serial_no': 1,
          'invoice_line_serial': 1,
          'product_id': batchProductId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': 2,
          'base_qty': 2,
          'rate': 60,
          'gross_amount': 120,
          'tax_amount': 0,
          'final_amount': 120,
        },
      ],
      'p_batches': [
        {'line_serial': 1, 'batch_no': batchNo, 'base_qty': 2},
      ],
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

    balance = await ScenarioHelpers.batchBalance(
      verifier, productId: batchProductId, locationId: TestTenantConfig.locationId, batchNo: batchNo,
    );
    expect(balance, 6, reason: '4 remaining + 2 returned back into the same batch');

    await ScenarioHelpers.assertTrialBalanceBalances(verifier, dateFrom: today, dateTo: today);
  });
}
