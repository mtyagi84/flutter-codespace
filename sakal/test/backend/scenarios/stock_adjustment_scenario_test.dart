import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

import 'scenario_helpers.dart';

/// Business scenario 7: Stock Adjustment, both '+' (increase) and '-'
/// (decrease) lines as two separate documents, verifying the Dr/Cr
/// direction genuinely FLIPS between the two (not just that both post
/// *something*), and that a '+' line with already-established cost does
/// NOT hit COST_NOT_ESTABLISHED.
///
/// Numbers: establish 10 units @ $50 (so cost exists for the '+' case),
/// adjust +5 then -3 as two distinct documents.
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

  test('Stock Adjustment: + and - flip Dr/Cr direction correctly', () async {
    final today = todayStr();

    await ScenarioHelpers.establishStockViaDirectGrn(verifier, refs, qty: 10, rate: 50);
    var stock = await ScenarioHelpers.stockAt(verifier, TestTenantConfig.locationId);
    expect(stock.currentStock, 10);

    // ── '+' adjustment: cost already established, must NOT be blocked ───
    final adjNoPlus = await verifier.rpc('fn_save_stock_adjustment', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'adjustment_no': null,
        'adjustment_date': today,
        'remarks': 'QA scenario test - increase',
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'adjust_flag': '+',
          'base_qty': 5,
        },
      ],
      'p_batches': [],
      'p_serials': [],
      'p_user_id': verifier.userId,
    }) as String;

    await verifier.rpc('fn_approve_stock_adjustment', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_adjustment_no': adjNoPlus,
      'p_adjustment_date': today,
      'p_approved_by': verifier.userId,
    });

    stock = await ScenarioHelpers.stockAt(verifier, TestTenantConfig.locationId);
    expect(stock.currentStock, 15, reason: '10 + 5 adjusted in');

    final plusLines = await ScenarioHelpers.financeLinesFor(
      verifier, sourceDocType: 'STOCK_ADJUSTMENT', sourceDocNo: adjNoPlus,
    );
    ScenarioHelpers.assertLinesBalance(plusLines);
    // Distinguished by source_line_type (076's own tags), NOT account_id —
    // CommonRefs.ensureStockAdjustmentAccountLink aliases
    // STOCK_ADJUSTMENT_ACCOUNT to the SAME account as STOCK_ACCOUNT in this
    // QA fixture, so both lines of a single adjustment share one
    // account_id and can't be told apart that way (confirmed live: an
    // account_id-based lookup picked whichever line happened to come
    // first, not the intended one). Migration 076 itself is correct —
    // this is purely a test-fixture-account-aliasing gotcha, same class
    // already hit in the Stock Transfer scenario.
    final plusStockLine = plusLines.firstWhere((l) => l['source_line_type'] == 'STOCK_INCREASE');
    expect(plusStockLine['trans_nature'], 'DR', reason: 'A + adjustment must Dr Stock');
    expect((plusStockLine['base_amount'] as num).toDouble(), closeTo(250, 0.01), reason: '5 units @ 50');

    // ── '-' adjustment: mirror-image direction ──────────────────────────
    final adjNoMinus = await verifier.rpc('fn_save_stock_adjustment', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'adjustment_no': null,
        'adjustment_date': today,
        'remarks': 'QA scenario test - decrease',
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'adjust_flag': '-',
          'base_qty': 3,
        },
      ],
      'p_batches': [],
      'p_serials': [],
      'p_user_id': verifier.userId,
    }) as String;

    await verifier.rpc('fn_approve_stock_adjustment', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_adjustment_no': adjNoMinus,
      'p_adjustment_date': today,
      'p_approved_by': verifier.userId,
    });

    stock = await ScenarioHelpers.stockAt(verifier, TestTenantConfig.locationId);
    expect(stock.currentStock, 12, reason: '15 - 3 adjusted out');

    final minusLines = await ScenarioHelpers.financeLinesFor(
      verifier, sourceDocType: 'STOCK_ADJUSTMENT', sourceDocNo: adjNoMinus,
    );
    ScenarioHelpers.assertLinesBalance(minusLines);
    final minusStockLine = minusLines.firstWhere((l) => l['source_line_type'] == 'STOCK_DECREASE');
    expect(minusStockLine['trans_nature'], 'CR',
        reason: 'A - adjustment must Cr Stock — the mirror image of the + case, not the same direction');
    expect((minusStockLine['base_amount'] as num).toDouble(), closeTo(150, 0.01), reason: '3 units @ 50');

    await ScenarioHelpers.assertTrialBalanceBalances(verifier, dateFrom: today, dateTo: today);
  });
}
