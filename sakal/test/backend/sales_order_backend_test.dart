import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for SL-SO (Sales Order) — calls
/// fn_save_sales_order/fn_approve_sales_order directly, DIRECT mode with a
/// manual price override (no Price Master row exists for this product in
/// the QA tenant — the QA admin user has `can_override_price=true`,
/// confirmed live, so this exercises the MANUAL_OVERRIDE price-source path
/// with a required override reason).
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

  test('Sales Order: DIRECT mode with price override, approve, cancel requires reason', () async {
    final today = DateTime.now().toIso8601String().split('T').first;

    final orderNo = await verifier.rpc('fn_save_sales_order', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'order_no': null,
        'order_date': today,
        'order_mode': 'DIRECT',
        'customer_id': TestTenantConfig.customerId,
        'order_currency_id': refs.currencyId,
        'rate_to_base': 1,
        'rate_to_local': 1,
        'gross_amount': 300,
        'grand_total': 300,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': 30,
          'base_qty': 30,
          'rate': 10,
          'price_override_reason': 'QA backend test - no Price Master row configured',
          'gross_amount': 300,
          'final_amount': 300,
          'base_amount': 300,
          'local_amount': 300,
        },
      ],
      'p_charges': [],
      'p_user_id': verifier.userId,
    });

    final draft = await verifier.getOne(
      'rih_sales_orders',
      {'order_no': 'eq.$orderNo'},
      select: 'order_no,status',
    );
    expect(draft['status'], 'DRAFT');

    await verifier.rpc('fn_approve_sales_order', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_order_no': orderNo,
      'p_order_date': today,
      'p_approved_by': verifier.userId,
    });

    final approved = await verifier.getOne(
      'rih_sales_orders',
      {'order_no': 'eq.$orderNo'},
      select: 'order_no,status',
    );
    expect(approved['status'], 'APPROVED');

    // No stock/GL effect — Sales Order never posts either (that's Sales
    // Invoice's job).
    final stockUnchanged = await verifier.getOne(
      'rim_product_location',
      {'product_id': 'eq.${TestTenantConfig.productId}', 'location_id': 'eq.${TestTenantConfig.locationId}'},
      select: 'current_stock',
    );
    expect((stockUnchanged['current_stock'] as num).toDouble(), 0);

    // Cancellation requires a mandatory reason (CLAUDE.md's Sales Order
    // section — fn_cancel_sales_order's p_reason is validated as its very
    // first statement).
    await expectLater(
      verifier.rpc('fn_cancel_sales_order', {
        'p_client_id': verifier.clientId,
        'p_company_id': verifier.companyId,
        'p_order_no': orderNo,
        'p_order_date': today,
        'p_reason': '',
        'p_user_id': verifier.userId,
      }),
      throwsA(anything),
      reason: 'Cancelling a Sales Order with an empty reason must be rejected',
    );

    await verifier.rpc('fn_cancel_sales_order', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_order_no': orderNo,
      'p_order_date': today,
      'p_reason': 'QA backend test cancellation',
      'p_user_id': verifier.userId,
    });

    final cancelled = await verifier.getOne(
      'rih_sales_orders',
      {'order_no': 'eq.$orderNo'},
      select: 'order_no,status',
    );
    expect(cancelled['status'], 'CANCELLED');
  });
}
