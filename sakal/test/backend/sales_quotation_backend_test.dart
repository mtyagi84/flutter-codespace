import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for SL-QUO (Sales Quotation) — calls
/// fn_save_sales_quotation/fn_approve_sales_quotation directly. Pure
/// pre-commitment offer, no GL/stock effect. Covers the CUSTOMER (not
/// PROSPECT) path.
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

  test('Sales Quotation: create DRAFT, approve, immutability blocked', () async {
    final today = DateTime.now().toIso8601String().split('T').first;

    final quotationNo = await verifier.rpc('fn_save_sales_quotation', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'quotation_no': null,
        'quotation_date': today,
        'valid_until_date': today,
        'customer_type': 'CUSTOMER',
        'customer_id': TestTenantConfig.customerId,
        'party_name': 'QA Test Customer',
        'quotation_currency_id': refs.currencyId,
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
      'rih_sales_quotations',
      {'quotation_no': 'eq.$quotationNo'},
      select: 'quotation_no,status',
    );
    expect(draft['status'], 'DRAFT');

    await verifier.rpc('fn_approve_sales_quotation', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_quotation_no': quotationNo,
      'p_quotation_date': today,
      'p_approved_by': verifier.userId,
    });

    final approved = await verifier.getOne(
      'rih_sales_quotations',
      {'quotation_no': 'eq.$quotationNo'},
      select: 'quotation_no,status',
    );
    expect(approved['status'], 'APPROVED');

    // No stock/GL effect — pure pre-commitment offer.
    final stockUnchanged = await verifier.getOne(
      'rim_product_location',
      {'product_id': 'eq.${TestTenantConfig.productId}', 'location_id': 'eq.${TestTenantConfig.locationId}'},
      select: 'current_stock',
    );
    expect((stockUnchanged['current_stock'] as num).toDouble(), 0,
        reason: 'A Sales Quotation must never move stock');

    // Immutability (CCC #5).
    await expectLater(
      verifier.rpc('fn_save_sales_quotation', {
        'p_header': {
          'client_id': verifier.clientId,
          'company_id': verifier.companyId,
          'location_id': TestTenantConfig.locationId,
          'quotation_no': quotationNo,
          'quotation_date': today,
          'valid_until_date': today,
          'customer_type': 'CUSTOMER',
          'customer_id': TestTenantConfig.customerId,
          'party_name': 'QA Test Customer',
          'quotation_currency_id': refs.currencyId,
          'gross_amount': 999,
          'grand_total': 999,
        },
        'p_lines': [
          {'serial_no': 1, 'product_id': TestTenantConfig.productId, 'uom_id': refs.uomId, 'base_qty': 99, 'rate': 10, 'final_amount': 990},
        ],
        'p_charges': [],
        'p_user_id': verifier.userId,
      }),
      throwsA(anything),
      reason: 'Editing an APPROVED Sales Quotation must be rejected',
    );
  });
}
