import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

import 'scenario_helpers.dart';

/// Business scenario 5: full Stock Transfer chain — Request -> Transfer
/// (against_request) -> Receipt — verifying the CUMULATIVE stock effect
/// across all three documents (not just each one in isolation, as the
/// existing per-document test files already do) and that the
/// STOCK_IN_TRANSIT_ACCOUNT genuinely nets to zero end to end.
///
/// Numbers: establish 10 units @ $50 at Location A, transfer 6 to Location B.
void main() {
  late BackendVerifier verifier;
  late CommonRefs refs;
  late String locationB;

  setUpAll(() async {
    verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);
    refs = await CommonRefs.load(verifier);
    locationB = await CommonRefs.loadOrCreateSecondLocation(verifier);
    await CommonRefs.ensureStockInTransitAccountLink(verifier);
  });

  test('Stock Transfer chain: Request -> Transfer -> Receipt, in-transit nets to zero', () async {
    final today = todayStr();
    const locationA = TestTenantConfig.locationId;

    await ScenarioHelpers.establishStockViaDirectGrn(verifier, refs, qty: 10, rate: 50, locationId: locationA);
    var a = await ScenarioHelpers.stockAt(verifier, locationA);
    expect(a.currentStock, 10);
    expect(a.costPrice, closeTo(50, 0.01));

    // ── Stock Transfer Request ──────────────────────────────────────────
    final requestNo = await verifier.rpc('fn_save_stock_transfer_request', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'from_location_id': locationA,
        'to_location_id': locationB,
        'request_no': null,
        'request_date': today,
        'remarks': 'QA scenario test',
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': 6,
          'qty_loose': 0,
          'base_qty': 6,
        },
      ],
      'p_user_id': verifier.userId,
    }) as String;

    await verifier.rpc('fn_approve_stock_transfer_request', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_request_no': requestNo,
      'p_request_date': today,
      'p_approved_by': verifier.userId,
    });

    // ── Stock Transfer, against_request:true ────────────────────────────
    final transferNo = await verifier.rpc('fn_save_stock_transfer', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'from_location_id': locationA,
        'to_location_id': locationB,
        'transfer_no': null,
        'transfer_date': today,
        'against_request': true,
        'source_request_no': requestNo,
        'source_request_date': today,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'source_request_no': requestNo,
          'source_request_date': today,
          'source_request_line_serial': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': 6,
          'base_qty': 6,
        },
      ],
      'p_batches': [],
      'p_serials': [],
      'p_charges': [],
      'p_user_id': verifier.userId,
    }) as String;

    await verifier.rpc('fn_approve_stock_transfer', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_transfer_no': transferNo,
      'p_transfer_date': today,
      'p_approved_by': verifier.userId,
    });

    // FROM drops immediately at Transfer-approval; TO is still untouched.
    a = await ScenarioHelpers.stockAt(verifier, locationA);
    expect(a.currentStock, 4, reason: '10 - 6 transferred out');
    var b = await ScenarioHelpers.stockAt(verifier, locationB);
    expect(b.currentStock, 0, reason: 'TRANSFER_OUT posts at Transfer approval; TO side only moves at Receipt');

    // ── Stock Receipt ────────────────────────────────────────────────────
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
          'received_qty_pack': 6,
          'received_qty_loose': 0,
          'received_base_qty': 6,
        },
      ],
      'p_batches': [],
      'p_serials': [],
      'p_user_id': verifier.userId,
    }) as String;

    await verifier.rpc('fn_approve_stock_receipt', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_receipt_no': receiptNo,
      'p_receipt_date': today,
      'p_approved_by': verifier.userId,
    });

    b = await ScenarioHelpers.stockAt(verifier, locationB);
    expect(b.currentStock, 6, reason: 'Receipt brings the full 6 units into Location B');
    a = await ScenarioHelpers.stockAt(verifier, locationA);
    expect(a.currentStock, 4, reason: 'Receipt never touches the FROM location');

    // Company-wide invariant: stock only MOVES location, total is conserved.
    expect(a.currentStock + b.currentStock, 10);

    // STOCK_IN_TRANSIT_ACCOUNT must net to exactly zero once both the
    // Transfer (debits/credits it going out) and the Receipt (the mirror
    // entry coming back in) have posted — this is the "clears end to end"
    // check the scenario is named for.
    final transferLines = await ScenarioHelpers.financeLinesFor(
      verifier, sourceDocType: 'STOCK_TRANSFER', sourceDocNo: transferNo,
    );
    final receiptLines = await ScenarioHelpers.financeLinesFor(
      verifier, sourceDocType: 'STOCK_RECEIPT', sourceDocNo: receiptNo,
    );
    // Filtered by source_line_type (038/CLAUDE.md's Finance-line-
    // traceability columns), NOT account_id — CommonRefs.
    // ensureStockInTransitAccountLink aliases STOCK_IN_TRANSIT_ACCOUNT to
    // the SAME account as STOCK_ACCOUNT in this QA fixture (no dedicated
    // "Stock in Transit" account in the seeded COA), which would make an
    // account_id-based net-to-zero check trivially true regardless of
    // whether the Transfer and Receipt amounts actually match each other
    // (each voucher already balances internally on its own by construction
    // via fn_post_voucher's own DR=CR check). Filtering by the DEDICATED
    // 'STOCK_IN_TRANSIT'/'STOCK_IN_TRANSIT_CLEARED' tags (073/074's own
    // jsonb_build_object keys) instead directly compares the specific pair
    // of lines whose amounts must match for the in-transit leg to
    // genuinely clear — a real signal, not an artifact of account aliasing.
    final transitOpenLine = transferLines.firstWhere((l) => l['source_line_type'] == 'STOCK_IN_TRANSIT');
    final transitClearedLine = receiptLines.firstWhere((l) => l['source_line_type'] == 'STOCK_IN_TRANSIT_CLEARED');
    expect(transitOpenLine['trans_nature'], 'DR');
    expect(transitClearedLine['trans_nature'], 'CR');
    expect(
      (transitClearedLine['base_amount'] as num).toDouble(),
      closeTo((transitOpenLine['base_amount'] as num).toDouble(), 0.01),
      reason: 'The Transfer\'s DR-in-transit amount and the Receipt\'s CR-clearing amount must match exactly for the in-transit leg to genuinely clear',
    );

    await ScenarioHelpers.assertTrialBalanceBalances(verifier, dateFrom: today, dateTo: today);
  });
}
