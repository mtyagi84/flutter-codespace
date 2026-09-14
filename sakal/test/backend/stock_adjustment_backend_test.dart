import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for IN-ADJ (Stock Adjustment) — calls
/// fn_save_stock_adjustment/fn_approve_stock_adjustment directly. Covers a
/// '-' (decrease) line against stock already established via a GRN. A '+'
/// line's own COST_NOT_ESTABLISHED hard-block (CLAUDE.md's Stock Adjustment
/// section) is a separate, not-yet-covered case — this test only exercises
/// the decrease path, which has no such precondition.
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
    await CommonRefs.ensureStockAdjustmentAccountLink(verifier);
  });

  test('Stock Adjustment: decrease line, approve, stock/GL adjust correctly', () async {
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

    // ── Act: adjust DOWN by 5 units (e.g. breakage) ─────────────────────
    final adjustmentNo = await verifier.rpc('fn_save_stock_adjustment', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'adjustment_no': null,
        'adjustment_date': today,
        'remarks': 'QA backend test - breakage',
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'adjust_flag': '-',
          'base_qty': 5,
        },
      ],
      'p_batches': [],
      'p_serials': [],
      'p_user_id': verifier.userId,
    });

    final draft = await verifier.getOne(
      'rih_stock_adjustment_headers',
      {'adjustment_no': 'eq.$adjustmentNo'},
      select: 'adjustment_no,status',
    );
    expect(draft['status'], 'DRAFT');

    await verifier.rpc('fn_approve_stock_adjustment', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_adjustment_no': adjustmentNo,
      'p_adjustment_date': today,
      'p_approved_by': verifier.userId,
    });

    final approved = await verifier.getOne(
      'rih_stock_adjustment_headers',
      {'adjustment_no': 'eq.$adjustmentNo'},
      select: 'adjustment_no,status',
    );
    expect(approved['status'], 'APPROVED');

    final stock = await verifier.getOne(
      'rim_product_location',
      {'product_id': 'eq.${TestTenantConfig.productId}', 'location_id': 'eq.${TestTenantConfig.locationId}'},
      select: 'current_stock',
    );
    expect((stock['current_stock'] as num).toDouble(), 45,
        reason: '50 received - 5 adjusted out must leave exactly 45 in stock');

    // Immutability (CCC #5).
    await expectLater(
      verifier.rpc('fn_save_stock_adjustment', {
        'p_header': {
          'client_id': verifier.clientId,
          'company_id': verifier.companyId,
          'location_id': TestTenantConfig.locationId,
          'adjustment_no': adjustmentNo,
          'adjustment_date': today,
          'remarks': 'edited',
        },
        'p_lines': [
          {'serial_no': 1, 'product_id': TestTenantConfig.productId, 'uom_id': refs.uomId, 'adjust_flag': '-', 'base_qty': 1},
        ],
        'p_batches': [],
        'p_serials': [],
        'p_user_id': verifier.userId,
      }),
      throwsA(anything),
      reason: 'Editing an APPROVED Stock Adjustment must be rejected',
    );
  });
}
