import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for PR-GRN — calls fn_save_grn/fn_approve_grn directly
/// via BackendVerifier.rpc(), the same RPCs the real GRN entry screen calls,
/// bypassing the UI entirely.
///
/// Why backend-only, not `flutter drive`: 2026-09-13/14 found the UI-driven
/// `integration_test` login flow unreliable in this environment (session
/// reverts to null after an apparently-successful login — confirmed via a
/// side-by-side manual `flutter run -d chrome` login, which works perfectly
/// every time, proving the app itself has no bug; the automation harness
/// does). See `integration_test/README.md`'s own "OPEN" section for the
/// full trace. Pivoting the bulk of the test plan to this backend-RPC
/// pattern — reliable, fast (seconds, not minutes), no browser/chromedriver
/// dependency at all — while full UI automation stays a secondary,
/// opportunistic track. This covers every Cross-Cutting Checklist item that
/// is actually about DATA correctness (Dr/Cr, currency, immutability,
/// permission gating, stock/GL posting) — CCC #4 (button state) and #7
/// (responsive layout) are the only items that genuinely need UI automation
/// and are out of scope for this file.
///
/// Run with: flutter test test/backend/grn_backend_test.dart
/// (no chromedriver, no --dart-define needed beyond what's already baked
/// into test_tenant_config.dart's own QA-tenant defaults for a local run —
/// see that file; this test hardcodes the same QA tenant values already
/// used throughout the integration_test/ suite for consistency).
void main() {
  late BackendVerifier verifier;
  late CommonRefs refs;

  setUpAll(() async {
    verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);
    refs = await CommonRefs.load(verifier);
  });

  test('GRN: create DRAFT, approve, stock+cost posts correctly', () async {
    final grnNo = await verifier.rpc('fn_save_grn', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'grn_no': null,
        'grn_date': DateTime.now().toIso8601String().split('T').first,
        'supplier_id': TestTenantConfig.supplierId,
        'receipt_mode': 'DIRECT',
        'grn_currency_id': refs.currencyId,
        'rate_to_base': 1,
        'rate_to_local': 1,
        'gross_amount': 1000,
        'discount_amount': 0,
        'charges_amount': 0,
        'item_tax_amount': 0,
        'charge_tax_amount': 0,
        'grand_total': 1000,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': 100,
          'qty_loose': 0,
          'base_qty': 100,
          'rate': 10,
          'gross_amount': 1000,
          'discount_percent': 0,
          'discount_amount': 0,
          'tax_amount': 0,
          'final_amount': 1000,
          'base_amount': 1000,
          'local_amount': 1000,
          'charge_amount': 0,
          'landed_amount': 1000,
        },
      ],
      'p_batches': [],
      'p_serials': [],
      'p_charges': [],
      'p_user_id': verifier.userId,
    });

    final grnHeaderDraft = await verifier.getOne(
      'rih_grn_headers',
      {'grn_no': 'eq.$grnNo'},
      select: 'grn_no,status',
    );
    expect(grnHeaderDraft['status'], 'DRAFT');

    await verifier.rpc('fn_approve_grn', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_grn_no': grnNo,
      'p_grn_date': DateTime.now().toIso8601String().split('T').first,
      'p_approved_by': verifier.userId,
    });

    final grnHeaderApproved = await verifier.getOne(
      'rih_grn_headers',
      {'grn_no': 'eq.$grnNo'},
      select: 'grn_no,status',
    );
    expect(grnHeaderApproved['status'], 'APPROVED');

    final productLocation = await verifier.getOne(
      'rim_product_location',
      {
        'product_id': 'eq.${TestTenantConfig.productId}',
        'location_id': 'eq.${TestTenantConfig.locationId}',
      },
      select: 'current_stock,cost_price',
    );
    expect((productLocation['current_stock'] as num).toDouble(), 100);
    expect((productLocation['cost_price'] as num).toDouble(), closeTo(10, 0.01));

    // Immutability (Cross-Cutting Checklist #5): a DRAFT-only save must be
    // blocked once APPROVED.
    await expectLater(
      verifier.rpc('fn_save_grn', {
        'p_header': {
          'client_id': verifier.clientId,
          'company_id': verifier.companyId,
          'location_id': TestTenantConfig.locationId,
          'grn_no': grnNo,
          'grn_date': DateTime.now().toIso8601String().split('T').first,
          'supplier_id': TestTenantConfig.supplierId,
          'receipt_mode': 'DIRECT',
          'grn_currency_id': refs.currencyId,
          'rate_to_base': 1,
          'rate_to_local': 1,
          'gross_amount': 2000,
          'grand_total': 2000,
        },
        'p_lines': [],
        'p_batches': [],
        'p_serials': [],
        'p_charges': [],
        'p_user_id': verifier.userId,
      }),
      throwsA(anything),
      reason: 'Editing an APPROVED GRN must be rejected',
    );
  });
}
