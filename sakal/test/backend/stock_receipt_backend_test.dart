import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for IN-SRC (Stock Receipt) — calls
/// fn_save_stock_receipt/fn_approve_stock_receipt directly, completing a
/// Stock Transfer (from_location_id/to_location_id are derived from the
/// source transfer itself, not supplied in the payload — confirmed by
/// reading fn_save_stock_receipt directly). Verifies stock arrives at the
/// TO location — the other half of stock_transfer_backend_test.dart's own
/// "stock leaves FROM" verification.
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

  test('Stock Receipt: complete a transfer, stock arrives at TO location', () async {
    final today = DateTime.now().toIso8601String().split('T').first;

    // ── Arrange: GRN at FROM, then an APPROVED Stock Transfer ──────────
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
    await verifier.rpc('fn_approve_stock_transfer', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_transfer_no': transferNo,
      'p_transfer_date': today,
      'p_approved_by': verifier.userId,
    });

    // ── Act: receive the transfer at TO ─────────────────────────────────
    final receiptNo = await verifier.rpc('fn_save_stock_receipt', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'receipt_no': null,
        'receipt_date': today,
        'source_transfer_no': transferNo,
        'source_transfer_date': today,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'source_transfer_line_serial': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'received_qty_pack': 15,
          'received_qty_loose': 0,
          'received_base_qty': 15,
        },
      ],
      'p_batches': [],
      'p_serials': [],
      'p_user_id': verifier.userId,
    });

    final draft = await verifier.getOne(
      'rih_stock_receipts',
      {'receipt_no': 'eq.$receiptNo'},
      select: 'receipt_no,status',
    );
    expect(draft['status'], 'DRAFT');

    await verifier.rpc('fn_approve_stock_receipt', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_receipt_no': receiptNo,
      'p_receipt_date': today,
      'p_approved_by': verifier.userId,
    });

    final approved = await verifier.getOne(
      'rih_stock_receipts',
      {'receipt_no': 'eq.$receiptNo'},
      select: 'receipt_no,status',
    );
    expect(approved['status'], 'APPROVED');

    final toStock = await verifier.getOne(
      'rim_product_location',
      {'product_id': 'eq.${TestTenantConfig.productId}', 'location_id': 'eq.$toLocationId'},
      select: 'current_stock',
    );
    expect((toStock['current_stock'] as num).toDouble(), 15,
        reason: 'Receiving the full transferred 15 units must show exactly 15 at the TO location');
  });
}
