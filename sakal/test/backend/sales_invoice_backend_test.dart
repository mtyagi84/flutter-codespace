import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for SL-INV (Sales Invoice / Quick Invoice) — calls
/// fn_save_sales_invoice/fn_approve_sales_invoice directly, DIRECT mode,
/// CREDIT sale (to the QA Test Customer, avoiding the cash-customer setup
/// a CASH sale needs), with a manual price override (no Price Master row
/// configured — same reasoning as sales_order_backend_test.dart). This is
/// the first Sales screen with real GL/stock impact — verifies stock
/// actually dispatches and both the SI and COS vouchers post.
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
  });

  test('Sales Invoice: DIRECT/CREDIT sale, approve, stock dispatches + GL posts', () async {
    final today = DateTime.now().toIso8601String().split('T').first;

    // ── Arrange: stock via a fresh GRN ─────────────────────────────────
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

    // ── Act: sell 10 units on credit ────────────────────────────────────
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

    final draft = await verifier.getOne(
      'rih_sales_invoices',
      {'invoice_no': 'eq.$invoiceNo'},
      select: 'invoice_no,status',
    );
    expect(draft['status'], 'DRAFT');

    await verifier.rpc('fn_approve_sales_invoice', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_invoice_no': invoiceNo,
      'p_invoice_date': today,
      'p_approved_by': verifier.userId,
    });

    final approved = await verifier.getOne(
      'rih_sales_invoices',
      {'invoice_no': 'eq.$invoiceNo'},
      select: 'invoice_no,status',
    );
    expect(approved['status'], 'APPROVED');

    final stock = await verifier.getOne(
      'rim_product_location',
      {'product_id': 'eq.${TestTenantConfig.productId}', 'location_id': 'eq.${TestTenantConfig.locationId}'},
      select: 'current_stock',
    );
    expect((stock['current_stock'] as num).toDouble(), 40,
        reason: '50 received - 10 sold must leave exactly 40 in stock');

    // Both the SI (Sales, invoice currency) and COS (Cost of Sales, base
    // currency) vouchers must post — CLAUDE.md's Sales Invoice section.
    final siHeader = await verifier.getOne(
      'rih_finance_headers',
      {'source_doc_type': 'eq.SALES_INVOICE', 'source_doc_no': 'eq.$invoiceNo', 'voucher_type_code': 'eq.SLS'},
      select: 'trans_no',
    );
    expect(siHeader['trans_no'], isNotNull);

    final cosHeader = await verifier.getOne(
      'rih_finance_headers',
      {'source_doc_type': 'eq.SALES_INVOICE', 'source_doc_no': 'eq.$invoiceNo', 'voucher_type_code': 'eq.COS'},
      select: 'trans_no',
    );
    expect(cosHeader['trans_no'], isNotNull);

    // Cancel is only allowed from DRAFT (CLAUDE.md: "no reversal path
    // exists in this build" once APPROVED) — an APPROVED invoice must
    // reject cancellation.
    await expectLater(
      verifier.rpc('fn_cancel_sales_invoice', {
        'p_client_id': verifier.clientId,
        'p_company_id': verifier.companyId,
        'p_invoice_no': invoiceNo,
        'p_invoice_date': today,
        'p_reason': 'QA backend test cancellation attempt',
        'p_user_id': verifier.userId,
      }),
      throwsA(anything),
      reason: 'Cancelling an APPROVED Sales Invoice must be rejected — no reversal path exists in this build',
    );
  });
}
