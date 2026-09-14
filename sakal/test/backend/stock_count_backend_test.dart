import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for IN-CNT (Stock Count) — calls
/// fn_save_stock_count/fn_submit_stock_count directly. Verifies the
/// blind-count DRAFT->SUBMITTED lifecycle only — the actual variance
/// posting happens one level up in Stock Count Review
/// (stock_count_review_backend_test.dart), which composes the existing
/// Stock Adjustment engine per CLAUDE.md's Stock Count section.
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

  test('Stock Count: create DRAFT worksheet, submit, immutability blocked', () async {
    final today = DateTime.now().toIso8601String().split('T').first;

    // ── Arrange: establish stock via a fresh GRN (50 units) ────────────
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

    // ── Act: count 45 units (blind — a real 5-unit shortage) ────────────
    final countNo = await verifier.rpc('fn_save_stock_count', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'count_no': null,
        'count_date': today,
        'remarks': 'QA backend test',
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'is_counted': true,
          'counted_qty_pack': 45,
          'counted_qty_loose': 0,
          'counted_base_qty': 45,
        },
      ],
      'p_batches': [],
      'p_serials': [],
      'p_user_id': verifier.userId,
    });

    final draft = await verifier.getOne(
      'rih_stock_count_headers',
      {'count_no': 'eq.$countNo'},
      select: 'count_no,status',
    );
    expect(draft['status'], 'DRAFT');

    await verifier.rpc('fn_submit_stock_count', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_count_no': countNo,
      'p_count_date': today,
      'p_user_id': verifier.userId,
    });

    final submitted = await verifier.getOne(
      'rih_stock_count_headers',
      {'count_no': 'eq.$countNo'},
      select: 'count_no,status',
    );
    expect(submitted['status'], 'SUBMITTED');

    // Stock is untouched by a mere count — this screen never posts a
    // stock movement itself, only Stock Count Review does (composing the
    // Stock Adjustment engine).
    final stockUnchanged = await verifier.getOne(
      'rim_product_location',
      {'product_id': 'eq.${TestTenantConfig.productId}', 'location_id': 'eq.${TestTenantConfig.locationId}'},
      select: 'current_stock',
    );
    expect((stockUnchanged['current_stock'] as num).toDouble(), 50,
        reason: 'A Stock Count by itself must never move stock — only Review does');

    // Immutability (CCC #5) — cannot edit a SUBMITTED count.
    await expectLater(
      verifier.rpc('fn_save_stock_count', {
        'p_header': {
          'client_id': verifier.clientId,
          'company_id': verifier.companyId,
          'location_id': TestTenantConfig.locationId,
          'count_no': countNo,
          'count_date': today,
          'remarks': 'edited',
        },
        'p_lines': [
          {
            'serial_no': 1,
            'product_id': TestTenantConfig.productId,
            'uom_id': refs.uomId,
            'is_counted': true,
            'counted_base_qty': 99,
          },
        ],
        'p_batches': [],
        'p_serials': [],
        'p_user_id': verifier.userId,
      }),
      throwsA(anything),
      reason: 'Editing a SUBMITTED Stock Count must be rejected',
    );
  });
}
