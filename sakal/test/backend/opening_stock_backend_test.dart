import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for IN-OPN (Opening Stock) — calls
/// fn_save_opening_stock/fn_approve_opening_stock directly. Must run
/// against a product/location with NO prior stock history — resetQaTenant()
/// zeroes rim_product_location.current_stock/cost_price (per
/// reset_all_transactions.sql's own documented behavior), so this test's
/// product/location combo is guaranteed clean at the start of each run.
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

  test('Opening Stock: establish starting qty+cost, approve, blocked on re-run', () async {
    final today = DateTime.now().toIso8601String().split('T').first;

    final openingNo = await verifier.rpc('fn_save_opening_stock', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'opening_no': null,
        'opening_date': today,
        'remarks': 'QA backend test',
      },
      'p_lines': [
        {
          'line_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'pack_qty': 25,
          'loose_qty': 0,
          'base_qty': 25,
          'unit_cost': 8,
        },
      ],
      'p_user_id': verifier.userId,
    });

    final draft = await verifier.getOne(
      'rih_opening_stock_headers',
      {'opening_no': 'eq.$openingNo'},
      select: 'opening_no,status',
    );
    expect(draft['status'], 'DRAFT');

    await verifier.rpc('fn_approve_opening_stock', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_opening_no': openingNo,
      'p_opening_date': today,
      'p_approved_by': verifier.userId,
    });

    final approved = await verifier.getOne(
      'rih_opening_stock_headers',
      {'opening_no': 'eq.$openingNo'},
      select: 'opening_no,status',
    );
    expect(approved['status'], 'APPROVED');

    final stock = await verifier.getOne(
      'rim_product_location',
      {'product_id': 'eq.${TestTenantConfig.productId}', 'location_id': 'eq.${TestTenantConfig.locationId}'},
      select: 'current_stock,cost_price',
    );
    expect((stock['current_stock'] as num).toDouble(), 25);
    expect((stock['cost_price'] as num).toDouble(), closeTo(8, 0.01));

    // OPENING_STOCK_ALREADY_ESTABLISHED (CLAUDE.md): a second opening-stock
    // document for the same product/location must be rejected at Approve,
    // since it already has stock/cost from the first one.
    final secondOpeningNo = await verifier.rpc('fn_save_opening_stock', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'opening_no': null,
        'opening_date': today,
        'remarks': 'QA backend test - duplicate',
      },
      'p_lines': [
        {
          'line_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'pack_qty': 10,
          'base_qty': 10,
          'unit_cost': 8,
        },
      ],
      'p_user_id': verifier.userId,
    });
    await expectLater(
      verifier.rpc('fn_approve_opening_stock', {
        'p_client_id': verifier.clientId,
        'p_company_id': verifier.companyId,
        'p_opening_no': secondOpeningNo,
        'p_opening_date': today,
        'p_approved_by': verifier.userId,
      }),
      throwsA(anything),
      reason: 'A second Opening Stock for a product/location that already has stock must be rejected (OPENING_STOCK_ALREADY_ESTABLISHED)',
    );

    // Immutability (CCC #5).
    await expectLater(
      verifier.rpc('fn_save_opening_stock', {
        'p_header': {
          'client_id': verifier.clientId,
          'company_id': verifier.companyId,
          'location_id': TestTenantConfig.locationId,
          'opening_no': openingNo,
          'opening_date': today,
          'remarks': 'edited',
        },
        'p_lines': [
          {'line_no': 1, 'product_id': TestTenantConfig.productId, 'uom_id': refs.uomId, 'base_qty': 99, 'unit_cost': 8},
        ],
        'p_user_id': verifier.userId,
      }),
      throwsA(anything),
      reason: 'Editing an APPROVED Opening Stock must be rejected',
    );
  });
}
