import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sakal/app.dart';
import 'package:sakal/core/router/route_names.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/report_diff.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

// screen_driver.dart depends on flutter_test (a dev-only package, not
// resolvable from anything under lib/) -- it must stay under
// integration_test/ rather than lib/test_support/ alongside the other
// support files, and can only be reached via a same-directory relative
// import: Flutter Web's integration_test build does NOT resolve a
// PARENT-directory relative import (`../support/...`) even though the
// identical code works fine on mobile/desktop -- confirmed live when this
// test was first run ("File not found" for every ../support/ import).
// Keeping this file in the SAME directory as the test itself sidesteps
// that entirely.
import 'screen_driver.dart';

/// The pilot flow from the approved E2E test automation plan: GRN -> Sales
/// Invoice -> Stock Ledger + Trial Balance, multi-currency (base=USD,
/// invoice currency=CDF) — the exact path that already caught the
/// SELLING/MID exchange-rate bug (fixed in 25b4806) earlier this session.
///
/// Success criteria per the plan:
///   1. Tenant reset runs cleanly.
///   2. ScreenDriver handles both entry screens with no per-screen hacks.
///   3. Backend verification + report diff catches a real regression —
///      the mutation test described in the plan (temporarily revert
///      25b4806, re-run, confirm this test's diff step fails) is a
///      separate manual step, not part of this file.
///   4. The report-diff logic (stock ledger net movement) is reusable.
///
/// `print()` checkpoints throughout: confirmed live 2026-09-13 that a run
/// can go completely silent for 15+ minutes with zero further `flutter
/// drive` CLI output between "Debug service listening" and either a result
/// or a timeout -- these checkpoints exist so the NEXT such silent run at
/// least shows which step it never got past, since the alternative is
/// re-diagnosing from zero information every time.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('GRN -> Sales Invoice zeroes out stock/COGS exactly (multi-currency)', (tester) async {
    print('[pilot] starting BackendVerifier.login()');
    final verifier = BackendVerifier();
    await verifier.login();
    print('[pilot] login() done, starting resetQaTenant()');
    await resetQaTenant(verifier);
    print('[pilot] resetQaTenant() done, pumping widget');

    // ── Launch the real app, log in through the real Login screen ────────
    // Deliberately NOT injecting a session via provider override — this
    // exercises the exact same fn_login call path a real user hits.
    await tester.pumpWidget(const ProviderScope(child: SakalApp()));
    print('[pilot] pumpWidget done, settling');
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 15));
    print('[pilot] initial settle done, entering login credentials');

    await tester.enterText(find.byKey(const Key('login_client_no')), TestTenantConfig.clientNo);
    await tester.enterText(find.byKey(const Key('login_username')), TestTenantConfig.username);
    await tester.enterText(find.byKey(const Key('login_password')), TestTenantConfig.password);
    await tester.tap(find.byKey(const Key('btn_login')));
    print('[pilot] login submitted, settling');
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 20));
    print('[pilot] logged in, navigating to GRN entry');

    final driver = ScreenDriver(tester);

    // ── GRN: receive 100 units at $10 USD/unit (base currency, no FX) ────
    await driver.navigateTo(RouteNames.grnEntry);
    print('[pilot] on GRN entry screen, filling supplier');
    await driver.fillForm({
      'grn_supplier_picker': const Select('QA Test Supplier'),
    });
    await tester.tap(find.byKey(const Key('btn_add_line')));
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 15));
    print('[pilot] filling GRN line');
    await driver.fillForm({
      'grn_line_product_0': const Select('QA Test Product'),
      'grn_line_qty_0': '100',
      'grn_line_rate_0': '10',
    });
    print('[pilot] submitting GRN');
    await driver.submit(saveButtonKey: 'btn_save');
    driver.expectNoErrorState();
    print('[pilot] GRN saved, verifying via backend');

    final grnHeader = await verifier.getOne(
      'rih_grn_headers',
      {'supplier_id': 'eq.${TestTenantConfig.supplierId}', 'order': 'created_at.desc', 'limit': '1'},
      select: 'grn_no,status',
    );
    expect(grnHeader['status'], 'DRAFT');
    print('[pilot] GRN ${grnHeader['grn_no']} confirmed DRAFT, approving');

    await driver.approve(approveButtonKey: 'btn_approve');
    driver.expectNoErrorState();
    print('[pilot] GRN approved, verifying');

    final grnAfterApprove = await verifier.getOne(
      'rih_grn_headers',
      {'grn_no': 'eq.${grnHeader['grn_no']}'},
      select: 'grn_no,status',
    );
    expect(grnAfterApprove['status'], 'APPROVED');

    final productLocation = await verifier.getOne(
      'rim_product_location',
      {'product_id': 'eq.${TestTenantConfig.productId}', 'location_id': 'eq.${TestTenantConfig.locationId}'},
      select: 'current_stock,cost_price',
    );
    expect((productLocation['current_stock'] as num).toDouble(), 100);
    expect((productLocation['cost_price'] as num).toDouble(), closeTo(10, 0.01));
    print('[pilot] stock confirmed at 100 units, navigating to Sales Invoice');

    // ── Sales Invoice: sell all 100 units to the QA customer, in CDF ─────
    // No Price Master row exists for this product -> the app's own
    // "Override Price" flow is required (matches real UX, not a shortcut —
    // see this session's own research into fn_save_sales_invoice's
    // PRICE_NOT_CONFIGURED / price_override_reason contract).
    await driver.navigateTo(RouteNames.salesInvoiceEntry);
    await driver.fillForm({
      'sale_type_segment': const Select('Credit'),
    });
    await driver.fillForm({
      'invoice_customer_picker': const Select('QA Test Customer'),
    });
    await driver.fillForm({
      'invoice_line_product_0': const Select('QA Test Product'),
      'invoice_line_qty_0': '100',
    });
    print('[pilot] filled invoice line, opening price override');
    await tester.tap(find.byKey(const Key('btn_override_price_0')));
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 15));
    await driver.fillForm({
      'invoice_line_rate_0': '30000', // CDF/unit -- an arbitrary sale price;
      // COGS correctness (the thing this pilot actually verifies) does not
      // depend on what the customer is charged.
      'invoice_line_reason_0': 'QA pilot test - no Price Master row configured',
    });
    print('[pilot] submitting Sales Invoice');
    await driver.submit(saveButtonKey: 'btn_save'); // Save IS Approve for this screen
    driver.expectNoErrorState();
    print('[pilot] Sales Invoice saved, verifying');

    final invoiceHeader = await verifier.getOne(
      'rih_sales_invoices',
      {'customer_id': 'eq.${TestTenantConfig.customerId}', 'order': 'created_at.desc', 'limit': '1'},
      select: 'invoice_no,status,invoice_currency_id',
    );
    expect(invoiceHeader['status'], 'APPROVED');
    print('[pilot] Invoice ${invoiceHeader['invoice_no']} confirmed APPROVED, running report diff');

    // ── The actual regression check: stock/COGS must zero out exactly ────
    final diff = ReportDiff(verifier);
    final netStockMovement = await diff.sumColumn(
      'ril_stock_ledger',
      'qty_change',
      {'product_id': 'eq.${TestTenantConfig.productId}', 'location_id': 'eq.${TestTenantConfig.locationId}'},
    );
    diff.expectClose(netStockMovement, 0, tolerance: 0.001, reason: 'Stock ledger net movement after buying and selling all 100 units');

    final productLocationAfterSale = await verifier.getOne(
      'rim_product_location',
      {'product_id': 'eq.${TestTenantConfig.productId}', 'location_id': 'eq.${TestTenantConfig.locationId}'},
      select: 'current_stock',
    );
    expect((productLocationAfterSale['current_stock'] as num).toDouble(), 0);

    // This is the exact check that would have caught the SELLING/MID bug:
    // sum every finance line touching the Stock account (the GRN's original
    // debit at purchase-side rate, plus the Sales Invoice's COGS credit at
    // whatever rate it used) and confirm it nets to zero in BASE currency.
    // If COGS and the GRN's own stock debit are ever computed from two
    // different rates again, this fails with a nonzero residual — exactly
    // the real bug this session found and fixed (25b4806).
    final stockAccountMovement = await diff.sumSignedByNature(
      'rid_finance_lines',
      'base_amount',
      {'account_id': 'eq.${TestTenantConfig.stockAccountId}'},
    );
    diff.expectClose(stockAccountMovement, 0, tolerance: 0.01, reason: 'Stock account net GL movement (base currency) after buying and selling all 100 units');
    print('[pilot] ALL ASSERTIONS PASSED');
  });
}
