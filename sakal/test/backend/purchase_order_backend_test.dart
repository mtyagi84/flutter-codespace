import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for PR-PO — calls fn_save_purchase_order/
/// fn_approve_purchase_order directly (same RPCs the entry screen calls).
/// See grn_backend_test.dart's own doc comment for why this pattern is
/// used instead of `flutter drive` UI automation.
void main() {
  late BackendVerifier verifier;
  late CommonRefs refs;

  setUpAll(() async {
    verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);
    refs = await CommonRefs.load(verifier);
  });

  test('PO: create DRAFT, approve, status transitions correctly', () async {
    final today = DateTime.now().toIso8601String().split('T').first;

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
          'qty_pack': 50,
          'qty_loose': 0,
          'base_qty': 50,
          'rate': 10,
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
    });

    final draft = await verifier.getOne(
      'rih_purchase_orders',
      {'order_no': 'eq.$orderNo'},
      select: 'order_no,status',
    );
    expect(draft['status'], 'DRAFT');

    await verifier.rpc('fn_approve_purchase_order', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_order_no': orderNo,
      'p_order_date': today,
      'p_approved_by': verifier.userId,
    });

    final approved = await verifier.getOne(
      'rih_purchase_orders',
      {'order_no': 'eq.$orderNo'},
      select: 'order_no,status',
    );
    expect(approved['status'], 'APPROVED');

    // Immutability (CCC #5): editing an APPROVED PO must be rejected.
    await expectLater(
      verifier.rpc('fn_save_purchase_order', {
        'p_header': {
          'client_id': verifier.clientId,
          'company_id': verifier.companyId,
          'location_id': TestTenantConfig.locationId,
          'order_no': orderNo,
          'order_date': today,
          'po_type': 'LOCAL',
          'supplier_id': TestTenantConfig.supplierId,
          'po_currency_id': refs.currencyId,
          'gross_amount': 999,
          'grand_total': 999,
        },
        'p_lines': [],
        'p_charges': [],
        'p_payment_terms': [],
        'p_user_id': verifier.userId,
      }),
      throwsA(anything),
      reason: 'Editing an APPROVED Purchase Order must be rejected',
    );

    // Empty-lines validation is enforced only at Approve, never at Draft
    // save (per fn_approve_purchase_order's own comment in migration 040) —
    // a zero-line DRAFT save must succeed, and only the subsequent Approve
    // attempt must raise PO_NO_LINES.
    final emptyOrderNo = await verifier.rpc('fn_save_purchase_order', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'order_no': null,
        'order_date': today,
        'po_type': 'LOCAL',
        'supplier_id': TestTenantConfig.supplierId,
        'po_currency_id': refs.currencyId,
        'gross_amount': 0,
        'grand_total': 0,
      },
      'p_lines': [],
      'p_charges': [],
      'p_payment_terms': [],
      'p_user_id': verifier.userId,
    });
    expect(emptyOrderNo, isNotNull, reason: 'A zero-line DRAFT save must succeed');

    await expectLater(
      verifier.rpc('fn_approve_purchase_order', {
        'p_client_id': verifier.clientId,
        'p_company_id': verifier.companyId,
        'p_order_no': emptyOrderNo,
        'p_order_date': today,
        'p_approved_by': verifier.userId,
      }),
      throwsA(anything),
      reason: 'Approving a Purchase Order with zero lines must be rejected (PO_NO_LINES)',
    );
  });
}
