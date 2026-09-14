import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for SL-RET (Sales Return) — calls
/// fn_save_sales_return/fn_approve_sales_return directly, against a fresh
/// CREDIT (not CASH) Sales Invoice with default IMMEDIATE dispatch (stock
/// already decreased at invoice approval), so this test verifies stock
/// genuinely comes BACK on a return, not just a status transition.
/// refund_amount_local/base are left at 0 — a credit return against an
/// outstanding CREDIT invoice just reduces the receivable, no cash refund
/// path (which would need the same Quick Invoice Setup fixture cash
/// receipt needed).
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
    await CommonRefs.ensureSalesReturnsAccountLink(verifier);
  });

  test('Sales Return: return against an APPROVED invoice, stock comes back', () async {
    final today = DateTime.now().toIso8601String().split('T').first;

    // ── Arrange: stock, then a CREDIT invoice (IMMEDIATE dispatch) ──────
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

    final stockAfterSale = await verifier.getOne(
      'rim_product_location',
      {'product_id': 'eq.${TestTenantConfig.productId}', 'location_id': 'eq.${TestTenantConfig.locationId}'},
      select: 'current_stock',
    );
    expect((stockAfterSale['current_stock'] as num).toDouble(), 40,
        reason: '50 received - 10 sold (IMMEDIATE dispatch) must leave exactly 40');

    // ── Act: return all 10 units ─────────────────────────────────────────
    final returnNo = await verifier.rpc('fn_save_sales_return', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'return_no': null,
        'return_date': today,
        'invoice_no': invoiceNo,
        'invoice_date': today,
        'taxable_amount': 100,
        'tax_amount': 0,
        'charges_amount': 0,
        'return_total': 100,
        'refund_amount_local': 0,
        'refund_amount_base': 0,
        'reason': 'QA backend test return',
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
          'rate': 10,
          'gross_amount': 100,
          'tax_amount': 0,
          'final_amount': 100,
        },
      ],
      'p_batches': [],
      'p_serials': [],
      'p_charges': [],
      'p_user_id': verifier.userId,
    });

    final draft = await verifier.getOne(
      'rih_sales_return_headers',
      {'return_no': 'eq.$returnNo'},
      select: 'return_no,status',
    );
    expect(draft['status'], 'DRAFT');

    await verifier.rpc('fn_approve_sales_return', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_return_no': returnNo,
      'p_return_date': today,
      'p_approved_by': verifier.userId,
    });

    final approved = await verifier.getOne(
      'rih_sales_return_headers',
      {'return_no': 'eq.$returnNo'},
      select: 'return_no,status',
    );
    expect(approved['status'], 'APPROVED');

    final stockAfterReturn = await verifier.getOne(
      'rim_product_location',
      {'product_id': 'eq.${TestTenantConfig.productId}', 'location_id': 'eq.${TestTenantConfig.locationId}'},
      select: 'current_stock',
    );
    expect((stockAfterReturn['current_stock'] as num).toDouble(), 50,
        reason: 'Returning all 10 sold units must bring stock back to exactly 50');
  });
}
