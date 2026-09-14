import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for PR-RET (Purchase Return) — calls
/// fn_save_purchase_return/fn_approve_purchase_return directly, against a
/// fresh UNBILLED GRN (the "reverses the still-provisional Accrual, posts
/// a JV" branch per CLAUDE.md's Purchase Return section — the billed/SDN
/// branch needs a Purchase Invoice first and is a follow-up).
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

  test('Purchase Return: return against an unbilled GRN, stock rolls back', () async {
    final today = DateTime.now().toIso8601String().split('T').first;

    // ── Arrange: a fresh APPROVED, UNBILLED GRN ────────────────────────
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
        'gross_amount': 1000,
        'grand_total': 1000,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': 100,
          'base_qty': 100,
          'rate': 10,
          'gross_amount': 1000,
          'final_amount': 1000,
          'base_amount': 1000,
          'local_amount': 1000,
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

    final stockAfterGrn = await verifier.getOne(
      'rim_product_location',
      {'product_id': 'eq.${TestTenantConfig.productId}', 'location_id': 'eq.${TestTenantConfig.locationId}'},
      select: 'current_stock',
    );
    expect((stockAfterGrn['current_stock'] as num).toDouble(), 100);

    // ── Act: return 30 of the 100 units ─────────────────────────────────
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
        'taxable_amount': 300,
        'tax_amount': 0,
        'return_total': 300,
        'reason': 'QA backend test — partial return',
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
          'qty_pack': 30,
          'qty_loose': 0,
          'base_qty': 30,
          'rate': 10,
          'gross_amount': 300,
          'tax_amount': 0,
          'final_amount': 300,
        },
      ],
      'p_batches': [],
      'p_serials': [],
      'p_charges': [],
      'p_user_id': verifier.userId,
    });

    final draft = await verifier.getOne(
      'rih_purchase_return_headers',
      {'return_no': 'eq.$returnNo'},
      select: 'return_no,status',
    );
    expect(draft['status'], 'DRAFT');

    await verifier.rpc('fn_approve_purchase_return', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_return_no': returnNo,
      'p_return_date': today,
      'p_reopen_po': false,
      'p_approved_by': verifier.userId,
    });

    final approved = await verifier.getOne(
      'rih_purchase_return_headers',
      {'return_no': 'eq.$returnNo'},
      select: 'return_no,status',
    );
    expect(approved['status'], 'APPROVED');

    final stockAfterReturn = await verifier.getOne(
      'rim_product_location',
      {'product_id': 'eq.${TestTenantConfig.productId}', 'location_id': 'eq.${TestTenantConfig.locationId}'},
      select: 'current_stock',
    );
    expect((stockAfterReturn['current_stock'] as num).toDouble(), 70,
        reason: 'Returning 30 of 100 units must leave exactly 70 in stock');

    // Immutability (CCC #5).
    await expectLater(
      verifier.rpc('fn_save_purchase_return', {
        'p_header': {
          'client_id': verifier.clientId,
          'company_id': verifier.companyId,
          'location_id': TestTenantConfig.locationId,
          'return_no': returnNo,
          'return_date': today,
          'supplier_id': TestTenantConfig.supplierId,
          'return_currency_id': refs.currencyId,
          'taxable_amount': 999,
          'return_total': 999,
          'reason': 'edited',
        },
        'p_lines': [
          {
            'serial_no': 1,
            'source_grn_no': grnNo,
            'source_grn_date': today,
            'source_grn_line_serial': 1,
            'product_id': TestTenantConfig.productId,
            'uom_id': refs.uomId,
            'base_qty': 1,
            'rate': 10,
            'final_amount': 10,
          },
        ],
        'p_batches': [],
        'p_serials': [],
        'p_charges': [],
        'p_user_id': verifier.userId,
      }),
      throwsA(anything),
      reason: 'Editing an APPROVED Purchase Return must be rejected',
    );
  });
}
