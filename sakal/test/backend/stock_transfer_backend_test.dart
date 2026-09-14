import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for IN-TRF (Stock Transfer) — calls
/// fn_save_stock_transfer/fn_approve_stock_transfer directly, DIRECT mode
/// (against_request=false), SAME_BOOK posting (QA tenant's
/// inter_location_model is SIMPLE, confirmed live). Verifies stock leaves
/// FROM immediately on Approve (TRANSFER_OUT) — the corresponding
/// TRANSFER_IN at TO happens on Stock Receipt, a separate screen/test.
///
/// See grn_backend_test.dart's doc comment for why this backend-RPC
/// pattern is used instead of `flutter drive` UI automation.
void main() {
  late BackendVerifier verifier;
  late CommonRefs refs;
  late String toLocationId;

  setUpAll(() async {
    verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);
    refs = await CommonRefs.load(verifier);
    toLocationId = await CommonRefs.loadOrCreateSecondLocation(verifier);
    await CommonRefs.ensureStockInTransitAccountLink(verifier);
  });

  test('Stock Transfer: create DRAFT, approve, stock leaves FROM location', () async {
    final today = DateTime.now().toIso8601String().split('T').first;

    // ── Arrange: stock at FROM via a fresh GRN ─────────────────────────
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
        'gross_amount': 400,
        'grand_total': 400,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': 40,
          'base_qty': 40,
          'rate': 10,
          'gross_amount': 400,
          'final_amount': 400,
          'base_amount': 400,
          'local_amount': 400,
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

    // ── Act: transfer 15 units to the second location ──────────────────
    final transferNo = await verifier.rpc('fn_save_stock_transfer', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'from_location_id': TestTenantConfig.locationId,
        'to_location_id': toLocationId,
        'transfer_no': null,
        'transfer_date': today,
        'against_request': false,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': 15,
          'base_qty': 15,
        },
      ],
      'p_batches': [],
      'p_serials': [],
      'p_charges': [],
      'p_user_id': verifier.userId,
    });

    final draft = await verifier.getOne(
      'rih_stock_transfers',
      {'transfer_no': 'eq.$transferNo'},
      select: 'transfer_no,status',
    );
    expect(draft['status'], 'DRAFT');

    await verifier.rpc('fn_approve_stock_transfer', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_transfer_no': transferNo,
      'p_transfer_date': today,
      'p_approved_by': verifier.userId,
    });

    final approved = await verifier.getOne(
      'rih_stock_transfers',
      {'transfer_no': 'eq.$transferNo'},
      select: 'transfer_no,status',
    );
    expect(approved['status'], 'APPROVED');

    final fromStock = await verifier.getOne(
      'rim_product_location',
      {'product_id': 'eq.${TestTenantConfig.productId}', 'location_id': 'eq.${TestTenantConfig.locationId}'},
      select: 'current_stock',
    );
    expect((fromStock['current_stock'] as num).toDouble(), 25,
        reason: '40 received - 15 transferred out must leave exactly 25 at the FROM location');

    // Immutability (CCC #5).
    await expectLater(
      verifier.rpc('fn_save_stock_transfer', {
        'p_header': {
          'client_id': verifier.clientId,
          'company_id': verifier.companyId,
          'from_location_id': TestTenantConfig.locationId,
          'to_location_id': toLocationId,
          'transfer_no': transferNo,
          'transfer_date': today,
          'against_request': false,
        },
        'p_lines': [
          {'serial_no': 1, 'product_id': TestTenantConfig.productId, 'uom_id': refs.uomId, 'base_qty': 99},
        ],
        'p_batches': [],
        'p_serials': [],
        'p_charges': [],
        'p_user_id': verifier.userId,
      }),
      throwsA(anything),
      reason: 'Editing an APPROVED Stock Transfer must be rejected',
    );
  });
}
