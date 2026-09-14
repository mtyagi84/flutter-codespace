import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for SL-DEL (Sales Delivery) — calls
/// fn_save_sales_delivery/fn_approve_sales_delivery directly, against a
/// Credit Sales Invoice (p_credit_invoice_screen=true forces always-
/// DEFERRED dispatch per CLAUDE.md, so stock is NOT yet moved at invoice
/// approval — exactly the precondition Sales Delivery needs to exist at
/// all). Verifies stock only leaves at Delivery time, not at invoice time.
///
/// This is the module where bug #4 (Save Draft/Approve buttons staying
/// enabled after Approve) was found and fixed earlier today (a172574) —
/// that fix is UI-only (a `setState` call), not testable from here; this
/// test instead confirms the underlying approve LOGIC (status transition,
/// stock movement) is correct, which is the data half of that same
/// Cross-Cutting Checklist item.
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

  test('Sales Delivery: dispatch a deferred Credit Sales Invoice, stock leaves only now', () async {
    final today = DateTime.now().toIso8601String().split('T').first;

    // ── Arrange: stock via GRN, then a Credit Sales Invoice (always
    // DEFERRED dispatch) ────────────────────────────────────────────────
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
      'p_credit_invoice_screen': true,
    });
    await verifier.rpc('fn_approve_sales_invoice', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_invoice_no': invoiceNo,
      'p_invoice_date': today,
      'p_approved_by': verifier.userId,
    });

    final stockAfterInvoice = await verifier.getOne(
      'rim_product_location',
      {'product_id': 'eq.${TestTenantConfig.productId}', 'location_id': 'eq.${TestTenantConfig.locationId}'},
      select: 'current_stock',
    );
    expect((stockAfterInvoice['current_stock'] as num).toDouble(), 50,
        reason: 'A Credit Sales Invoice always defers dispatch — stock must NOT move at invoice approval');

    // ── Act: deliver the invoice ─────────────────────────────────────────
    final deliveryNo = await verifier.rpc('fn_save_sales_delivery', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'delivery_no': null,
        'delivery_date': today,
        'invoice_no': invoiceNo,
        'invoice_date': today,
        'received_by_name': 'QA Backend Test',
      },
      'p_lines': [
        {
          'serial_no': 1,
          'invoice_line_serial': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': 10,
          'base_qty': 10,
        },
      ],
      'p_batches': [],
      'p_serials': [],
      'p_transport': null,
      'p_user_id': verifier.userId,
    });

    final draft = await verifier.getOne(
      'rih_sales_delivery_headers',
      {'delivery_no': 'eq.$deliveryNo'},
      select: 'delivery_no,status',
    );
    expect(draft['status'], 'DRAFT');

    await verifier.rpc('fn_approve_sales_delivery', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_delivery_no': deliveryNo,
      'p_delivery_date': today,
      'p_approved_by': verifier.userId,
    });

    final approved = await verifier.getOne(
      'rih_sales_delivery_headers',
      {'delivery_no': 'eq.$deliveryNo'},
      select: 'delivery_no,status',
    );
    expect(approved['status'], 'APPROVED');

    final stockAfterDelivery = await verifier.getOne(
      'rim_product_location',
      {'product_id': 'eq.${TestTenantConfig.productId}', 'location_id': 'eq.${TestTenantConfig.locationId}'},
      select: 'current_stock',
    );
    expect((stockAfterDelivery['current_stock'] as num).toDouble(), 40,
        reason: 'Stock must decrease by exactly the delivered quantity, only now at Delivery approval');

    // Immutability (CCC #5).
    await expectLater(
      verifier.rpc('fn_approve_sales_delivery', {
        'p_client_id': verifier.clientId,
        'p_company_id': verifier.companyId,
        'p_delivery_no': deliveryNo,
        'p_delivery_date': today,
        'p_approved_by': verifier.userId,
      }),
      throwsA(anything),
      reason: 'Approving an already-APPROVED Sales Delivery again must be rejected',
    );
  });
}
