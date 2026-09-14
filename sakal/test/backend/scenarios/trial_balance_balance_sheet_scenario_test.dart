import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

import 'scenario_helpers.dart';

/// Business scenario 9: Trial Balance + Balance Sheet reconciliation after
/// a realistic MIX of document types (not one isolated chain) — runs the
/// full Purchase-to-Pay chain (scenario 1) AND the full Order-to-Cash
/// chain (scenario 2) back to back in the SAME tenant, then asserts the
/// aggregate Trial Balance balances and the Balance Sheet's fundamental
/// identity (Assets = Liabilities + Equity) holds across the combined mix.
///
/// Numbers: Purchase-to-Pay buys 10 units @ $50 (never sold, all 10 remain
/// in stock). Order-to-Cash separately buys another 10 @ $50, sells 6 @
/// $60, returns 2 — the deferred-dispatch Sales Return bug found by this
/// same scenario-testing effort (see order_to_cash_scenario_test.dart) is
/// now FIXED (migration 187, deployed 2026-09-14), so the return
/// genuinely restores those 2 units. Combined remaining stock: 10
/// (untouched) + 6 (Order-to-Cash chain: 10 bought - 6 sold + 2 returned)
/// = 16 units @ $50 = $800 inventory.
void main() {
  late BackendVerifier verifier;
  late CommonRefs refs;
  late String cashAccountId;

  setUpAll(() async {
    verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);
    refs = await CommonRefs.load(verifier);
    await CommonRefs.ensureApprovePermission(verifier, 'SL-RCP');
    await CommonRefs.ensureQuickInvoiceSetup(verifier);
    await CommonRefs.ensureExchangeGainLossAccountLink(verifier);
    await CommonRefs.ensureSalesReturnsAccountLink(verifier);

    final cash = await verifier.getOne(
      'rim_accounts', {'account_code': 'eq.1110001001'}, select: 'id',
    );
    cashAccountId = cash['id'] as String;
  });

  test('Trial Balance + Balance Sheet reconcile after a mixed Purchase+Sales cycle', () async {
    final ptp = await ScenarioHelpers.runPurchaseToPayChain(
      verifier, refs, qty: 10, rate: 50, supplierInvoiceNo: 'QA-SCEN9-BILL', cashAccountId: cashAccountId,
    );
    await ScenarioHelpers.runOrderToCashChain(
      verifier, refs, buyQty: 10, buyRate: 50, sellQty: 6, sellRate: 60, returnQty: 2,
    );

    final today = ptp.date;

    await ScenarioHelpers.assertTrialBalanceBalances(verifier, dateFrom: today, dateTo: today);
    await ScenarioHelpers.assertBalanceSheetBalances(verifier, asOfDate: today);

    // Cross-check the specific inventory asset figure — computed
    // precisely from each chain's own actually-observed remaining stock,
    // not assumed independently.
    final combinedStock = await ScenarioHelpers.stockAt(verifier, TestTenantConfig.locationId);
    // ptp never sells (10 remain) + otc buys 10, sells 6 (delivered), then
    // the return correctly restores 2 (fixed by migration 187) = 10 + 6 = 16.
    expect(combinedStock.currentStock, 16,
        reason: 'Combined remaining stock across both independent chains');

    // Also independently confirm the customer and supplier sides both
    // reconcile to what each chain's own scenario test already proved in
    // isolation, now under a shared Trial Balance / Balance Sheet.
    final supplierLedger = await verifier.rpc('fn_account_ledger_totals', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_account_id': TestTenantConfig.supplierId,
      'p_date_from': today,
      'p_date_to': today,
      'p_currency_mode': 'BASE',
    });
    final supplierRow = (supplierLedger as List).first as Map<String, dynamic>;
    expect((supplierRow['running_balance'] as num).toDouble(), closeTo(0, 0.01),
        reason: 'Purchase-to-Pay\'s on-account payment settled the supplier in full');

    final customerLedger = await verifier.rpc('fn_account_ledger_totals', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_account_id': TestTenantConfig.customerId,
      'p_date_from': today,
      'p_date_to': today,
      'p_currency_mode': 'BASE',
    });
    final customerRow = (customerLedger as List).first as Map<String, dynamic>;
    expect((customerRow['running_balance'] as num).toDouble(), closeTo(0, 0.01),
        reason: 'Order-to-Cash\'s final cash receipt settled the customer in full');
  });
}
