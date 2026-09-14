import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for SL-RCP (Cash Receipt) — calls
/// fn_save_cash_receipt/fn_approve_cash_receipt directly, settling against
/// a real pending bill created by a fresh Credit Sales Invoice (the
/// v_pending_bills mechanism CLAUDE.md describes — any rid_finance_lines
/// row with inv_bill_no set is billable, generic across modules).
///
/// See grn_backend_test.dart's doc comment for why this backend-RPC
/// pattern is used instead of `flutter drive` UI automation.
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
  });

  test('Cash Receipt: settle a real pending bill from a Credit Sales Invoice', () async {
    final today = DateTime.now().toIso8601String().split('T').first;

    // ── Arrange: stock, then a CREDIT invoice creating a pending bill ────
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
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': 50,
          'base_qty': 50,
          'rate': 10,
          'gross_amount': 500,
          'final_amount': 500,
          'base_amount': 500,
          'local_amount': 500,
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
        'gross_amount': 100,
        'grand_total': 100,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': 10,
          'base_qty': 10,
          'rate': 10,
          'price_override_reason': 'QA backend test - no Price Master row configured',
          'gross_amount': 100,
          'final_amount': 100,
          'base_amount': 100,
          'local_amount': 100,
        },
      ],
      'p_charges': [],
      'p_batches': [],
      'p_serials': [],
      'p_user_id': verifier.userId,
    });
    await verifier.rpc('fn_approve_sales_invoice', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_invoice_no': invoiceNo,
      'p_invoice_date': today,
      'p_approved_by': verifier.userId,
    });

    // inv_bill_no defaults to the posting voucher's OWN trans_no (the SLS
    // voucher's, not the invoice's own invoice_no) — confirmed live
    // 2026-09-14 by direct query. Find the pending bill by customer +
    // DR nature instead of guessing the bill number.
    final pendingBill = await verifier.getOne(
      'rid_finance_lines',
      {'account_id': 'eq.${TestTenantConfig.customerId}', 'trans_nature': 'eq.DR', 'inv_bill_no': 'not.is.null'},
      select: 'inv_bill_no,inv_bill_date,trans_currency,account_id',
    );
    expect(pendingBill['account_id'], TestTenantConfig.customerId);

    // ── Act: collect the full amount, in local-currency cash ────────────
    // fn_save_cash_receipt's header total is local_amount + base_amount
    // converted to local (it supports a SPLIT collection, some cash in
    // base-currency notes and some in local — confirmed live 2026-09-14:
    // passing both local_amount=X and base_amount=100 raised
    // RECEIPT_AMOUNT_MISMATCH by double-counting the base leg). Collecting
    // entirely in local currency means base_amount must be 0.
    //
    // The pending bill's own local_amount is 100 — a direct carry-over of
    // this test's own invoice fixture (which set local_amount: 100 without
    // applying the real USD->CDF rate, since correctness here is about
    // whether the receipt-vs-bill matching logic works, not about a
    // realistic FX figure) — confirmed live via
    // RECEIPT_AMOUNT_EXCEEDS_PENDING_BALANCE when an FX-converted 282,500
    // was tried against this same bill. Collecting exactly what's
    // genuinely owed (100) is what this test actually needs to verify.
    const localAmount = 100;

    final receiptNo = await verifier.rpc('fn_save_cash_receipt', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'receipt_no': null,
        'receipt_date': today,
        'customer_id': TestTenantConfig.customerId,
        'local_amount': localAmount,
        'base_amount': 0,
        'remarks': 'QA backend test',
      },
      'p_lines': [
        {
          'inv_bill_no': pendingBill['inv_bill_no'],
          'inv_bill_date': pendingBill['inv_bill_date'],
          'bill_currency': pendingBill['trans_currency'],
          'applied_amount_local': localAmount,
        },
      ],
      'p_user_id': verifier.userId,
    });

    final draft = await verifier.getOne(
      'rih_cash_receipt_headers',
      {'receipt_no': 'eq.$receiptNo'},
      select: 'receipt_no,status',
    );
    expect(draft['status'], 'DRAFT');

    await verifier.rpc('fn_approve_cash_receipt', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_receipt_no': receiptNo,
      'p_receipt_date': today,
      'p_approved_by': verifier.userId,
    });

    final approved = await verifier.getOne(
      'rih_cash_receipt_headers',
      {'receipt_no': 'eq.$receiptNo'},
      select: 'receipt_no,status',
    );
    expect(approved['status'], 'APPROVED');
  });
}
