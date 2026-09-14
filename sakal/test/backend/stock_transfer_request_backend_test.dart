import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for IN-STR (Stock Transfer Request) — calls
/// fn_save_stock_transfer_request/fn_approve_stock_transfer_request
/// directly. Pure intent, no stock/GL effect (mirrors PO's role relative to
/// GRN) — this test only verifies the document lifecycle, not any stock
/// movement (Stock Transfer itself, consuming this request, is a separate
/// screen/test).
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
  });

  test('Stock Transfer Request: create DRAFT, approve, immutability blocked', () async {
    final today = DateTime.now().toIso8601String().split('T').first;

    final requestNo = await verifier.rpc('fn_save_stock_transfer_request', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'from_location_id': TestTenantConfig.locationId,
        'to_location_id': toLocationId,
        'request_no': null,
        'request_date': today,
        'remarks': 'QA backend test',
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': 10,
          'qty_loose': 0,
          'base_qty': 10,
        },
      ],
      'p_user_id': verifier.userId,
    });

    final draft = await verifier.getOne(
      'rih_stock_transfer_requests',
      {'request_no': 'eq.$requestNo'},
      select: 'request_no,status',
    );
    expect(draft['status'], 'DRAFT');

    await verifier.rpc('fn_approve_stock_transfer_request', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_request_no': requestNo,
      'p_request_date': today,
      'p_approved_by': verifier.userId,
    });

    final approved = await verifier.getOne(
      'rih_stock_transfer_requests',
      {'request_no': 'eq.$requestNo'},
      select: 'request_no,status',
    );
    expect(approved['status'], 'APPROVED');

    // Immutability (CCC #5).
    await expectLater(
      verifier.rpc('fn_save_stock_transfer_request', {
        'p_header': {
          'client_id': verifier.clientId,
          'company_id': verifier.companyId,
          'from_location_id': TestTenantConfig.locationId,
          'to_location_id': toLocationId,
          'request_no': requestNo,
          'request_date': today,
          'remarks': 'edited',
        },
        'p_lines': [
          {'serial_no': 1, 'product_id': TestTenantConfig.productId, 'uom_id': refs.uomId, 'base_qty': 99},
        ],
        'p_user_id': verifier.userId,
      }),
      throwsA(anything),
      reason: 'Editing an APPROVED Stock Transfer Request must be rejected',
    );
  });
}
