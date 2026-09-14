import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'scenario_helpers.dart';

/// Business scenario 10: Trial Balance + Profit & Loss reconciliation —
/// verifies P&L's own net_profit flows correctly into the Balance Sheet's
/// synthetic "Current Year Earnings" EQUITY node (144_balance_sheet_
/// hierarchical.sql line ~252-259, sentinel UUID
/// '00000000-0000-0000-0000-000000000001', sourced directly from
/// fn_pl_totals_base(fy_start_date, as_of_date)).
///
/// income_total is hand-verifiable exactly ($360 sold - $120 returned =
/// $240, since revenue reversal on return is a SEPARATE, unconditional
/// code path — 099_sales_return.sql's v_crn_lines block). expense_total/
/// net_profit are DELIBERATELY not asserted as exact hand-derived numbers
/// here: settling a PARTIAL residual balance via Cash Receipt after a
/// Sales Return also triggers a real Exchange Gain/Loss ('EXC') voucher
/// (104_cash_receipt.sql line ~656) — confirmed live to post ~$239.91 to
/// the fixture's shared EXCHANGE_GAIN_LOSS_ACCOUNT stand-in, itself a side
/// effect of this test's own nominal (non-real-FX) local_amount
/// convention (same documented convention as cash_receipt_backend_test.
/// dart) meeting a genuinely different code path once a bill is partially
/// settled after a return — a test-fixture artifact, not an app bug.
/// (The Sales-Return-doesn't-reverse-COGS-for-deferred-dispatch bug this
/// same scenario-testing effort found is now FIXED — migration 187,
/// deployed 2026-09-14 — so expense_total DOES correctly include the
/// COGS reversal; it just isn't asserted to an exact hand-derived number
/// here because of the separate FX-noise complication above.) Rather than
/// asserting a number that depends on an unrelated fixture artifact, this
/// test asserts the thing scenario 10 actually exists to prove: whatever
/// P&L's net_profit comes out to, the Balance Sheet's own Current Year
/// Earnings node exactly equals it.
void main() {
  late BackendVerifier verifier;
  late CommonRefs refs;

  setUpAll(() async {
    verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);
    refs = await CommonRefs.load(verifier);
    await CommonRefs.ensureApprovePermission(verifier, 'SL-RCP');
    await CommonRefs.ensureQuickInvoiceSetup(verifier);
    await CommonRefs.ensureExchangeGainLossAccountLink(verifier);
    await CommonRefs.ensureSalesReturnsAccountLink(verifier);
  });

  test('P&L net_profit flows correctly into Balance Sheet\'s Current Year Earnings', () async {
    await ScenarioHelpers.runOrderToCashChain(
      verifier, refs, buyQty: 10, buyRate: 50, sellQty: 6, sellRate: 60, returnQty: 2,
    );
    final today = todayStr();

    final fy = await verifier.getOne(
      'rim_financial_years', {'is_active': 'eq.true'}, select: 'fy_start_date',
    );
    final fyStart = fy['fy_start_date'] as String;

    final plResult = await verifier.rpc('fn_pl_totals_base', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_date_from': fyStart,
      'p_date_to': today,
    });
    final plRow = (plResult as List).first as Map<String, dynamic>;
    expect((plRow['income_total'] as num).toDouble(), closeTo(240, 0.01),
        reason: 'Revenue reversal on return is exact and hand-verifiable regardless of the COGS-reversal bug');
    final netProfit = (plRow['net_profit'] as num).toDouble();
    expect(netProfit, closeTo((plRow['income_total'] as num).toDouble() - (plRow['expense_total'] as num).toDouble(), 0.01),
        reason: 'net_profit must equal income_total - expense_total, whatever those individually come out to');

    await ScenarioHelpers.assertTrialBalanceBalances(verifier, dateFrom: today, dateTo: today);

    final bsResult = await verifier.rpc('fn_balance_sheet_tree_base', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_as_of_date': today,
      'p_leaves_included': false,
    });
    final rows = (bsResult as List).cast<Map<String, dynamic>>();
    final earningsNode = rows.firstWhere(
      (r) => r['node_id'] == '00000000-0000-0000-0000-000000000001',
      orElse: () => throw StateError('Current Year Earnings synthetic node not found in Balance Sheet tree — expected always-present per 144_balance_sheet_hierarchical.sql'),
    );
    expect(earningsNode['node_name'], 'Current Year Earnings');
    expect((earningsNode['amount'] as num).toDouble(), closeTo(netProfit, 0.01),
        reason: 'The Balance Sheet\'s own Current Year Earnings node must exactly equal P&L\'s net_profit ($netProfit) — this IS the actual P&L-to-Balance-Sheet reconciliation this scenario exists to prove');

    await ScenarioHelpers.assertBalanceSheetBalances(verifier, asOfDate: today);
  });
}
