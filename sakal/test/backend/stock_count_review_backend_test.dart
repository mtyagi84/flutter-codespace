import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for IN-CNR (Stock Count Review) — calls
/// fn_save_stock_count_review/fn_approve_stock_count_review directly.
/// Composes the EXISTING Stock Adjustment engine internally (per
/// CLAUDE.md's Stock Count section) to post the counted-vs-system
/// variance as a real stock adjustment — this test verifies that
/// composition actually moves stock by the correct (negative) amount for
/// a real shortage. Needs the same STOCK_ADJUSTMENT_ACCOUNT link Stock
/// Adjustment's own test needed (see stock_adjustment_backend_test.dart).
///
/// See grn_backend_test.dart's doc comment for why this backend-RPC
/// pattern is used instead of `flutter drive` UI automation.
void main() {
  late BackendVerifier verifier;
  late CommonRefs refs;
  late String reasonId;

  setUpAll(() async {
    verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);
    refs = await CommonRefs.load(verifier);
    await CommonRefs.ensureStockAdjustmentAccountLink(verifier);

    // fn_approve_stock_count_review requires reason_id ("A reason must be
    // selected before this Review can be approved" — confirmed live
    // 2026-09-14). The QA tenant's Common Masters already seed a
    // "Physical Count Variance" Stock Adjustment Reason for exactly this
    // scenario.
    final reasonType = await verifier.getUnscoped('rim_common_master_types', const {}, select: 'id,type_name');
    final reasonTypeId = reasonType.firstWhere((t) => t['type_name'] == 'Stock Adjustment Reason')['id'] as String;
    final reason = await verifier.getOne(
      'rim_common_masters',
      {'type_id': 'eq.$reasonTypeId', 'description': 'eq.Physical Count Variance'},
      select: 'id',
    );
    reasonId = reason['id'] as String;
  });

  test('Stock Count Review: approve posts the real variance as a Stock Adjustment', () async {
    final today = DateTime.now().toIso8601String().split('T').first;

    // ── Arrange: GRN (50 units) -> Count (45 counted) -> Submit ─────────
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

    final countNo = await verifier.rpc('fn_save_stock_count', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'count_no': null,
        'count_date': today,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'is_counted': true,
          'counted_qty_pack': 45,
          'counted_base_qty': 45,
        },
      ],
      'p_batches': [],
      'p_serials': [],
      'p_user_id': verifier.userId,
    });
    await verifier.rpc('fn_submit_stock_count', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_count_no': countNo,
      'p_count_date': today,
      'p_user_id': verifier.userId,
    });

    // ── Act: club the count into a Review, approve it ───────────────────
    final reviewNo = await verifier.rpc('fn_save_stock_count_review', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'review_no': null,
        'review_date': today,
        'as_of_date': today,
        'reason_id': reasonId,
        'remarks': 'QA backend test',
      },
      'p_source_refs': [
        {'source_count_no': countNo, 'source_count_date': today},
      ],
      'p_user_id': verifier.userId,
    });

    final draft = await verifier.getOne(
      'rih_stock_count_review_headers',
      {'review_no': 'eq.$reviewNo'},
      select: 'review_no,status',
    );
    expect(draft['status'], 'DRAFT');

    await verifier.rpc('fn_approve_stock_count_review', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_review_no': reviewNo,
      'p_review_date': today,
      'p_approved_by': verifier.userId,
    });

    final approved = await verifier.getOne(
      'rih_stock_count_review_headers',
      {'review_no': 'eq.$reviewNo'},
      select: 'review_no,status',
    );
    expect(approved['status'], 'APPROVED');

    final stock = await verifier.getOne(
      'rim_product_location',
      {'product_id': 'eq.${TestTenantConfig.productId}', 'location_id': 'eq.${TestTenantConfig.locationId}'},
      select: 'current_stock',
    );
    expect((stock['current_stock'] as num).toDouble(), 45,
        reason: 'A real 5-unit shortage (50 system vs 45 counted) must post an auto-adjustment down to exactly 45');

    // The auto-posted adjustment must trace back to this Review, per
    // rih_stock_adjustment_headers.source_doc_type (CLAUDE.md's Stock Count
    // section) — proof the composition actually happened, not merely that
    // stock happens to match by coincidence.
    final autoAdjustment = await verifier.getOne(
      'rih_stock_adjustment_headers',
      {'source_doc_type': 'eq.STOCK_COUNT_REVIEW', 'source_doc_no': 'eq.$reviewNo'},
      select: 'adjustment_no,status',
    );
    expect(autoAdjustment['status'], 'APPROVED');
  });
}
