import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sakal/app.dart';
import 'package:sakal/core/router/route_names.dart';
import 'package:sakal/core/services/local_storage.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

// screen_driver.dart must stay a same-directory relative import — see
// grn_to_sales_invoice_pilot_test.dart's own comment for why (Flutter Web's
// integration_test build doesn't resolve a parent-directory import).
import 'screen_driver.dart';

/// Standalone, single-screen GRN test — split out of
/// grn_to_sales_invoice_pilot_test.dart (2026-09-13) after confirming
/// chained multi-screen flows (GRN -> Sales Invoice in one file/session)
/// hang in this Flutter-Web integration_test environment, while an
/// independent single-screen test in its own file/run does not. This file
/// does its own reset + login + drive + verify, with no dependency on any
/// other test file's state.
///
/// Exercises: PR-GRN — Create (DRAFT) + Approve, and asserts the resulting
/// stock/cost effect directly against the backend (never scraped from the
/// UI) per the Cross-Cutting Checklist in `00_INDEX.md` (#4 button/status
/// state after an action is checked via the backend row's own `status`
/// column here, not a UI-side disabled-button assertion — that half of CCC
/// #4 needs a widget-tree assertion once Sales Delivery/GRN's own
/// post-approve button state is in scope for a dedicated test).
///
/// KNOWN UNRELIABLE as of 2026-09-14 — see integration_test/README.md's
/// "OPEN" section: `driver.login()` intermittently reverts session to null
/// after an apparently-successful login, confirmed NOT an app bug (manual
/// `flutter run -d chrome` login works every time). The equivalent backend-
/// only coverage (no UI, no browser, reliable) is
/// `test/backend/grn_backend_test.dart` — prefer that until this is
/// root-caused.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('GRN entry: create DRAFT, approve, stock+cost posts correctly', (tester) async {
    final verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);

    // main.dart's real bootstrap awaits LocalStorage.init() before runApp —
    // an integration_test that pumps SakalApp() directly must replicate
    // that, or every LocalStorage getter (clientNo, deviceOfflineEnabled,
    // ...) throws LateInitializationError the moment app.dart's own
    // startup path touches one. Confirmed live 2026-09-13.
    await LocalStorage.init();

    await tester.pumpWidget(const ProviderScope(child: SakalApp()));

    final driver = ScreenDriver(tester);
    await driver.login();

    await driver.navigateTo(RouteNames.grnEntry);
    await driver.fillForm({
      'grn_supplier_picker': const Select('QA Test Supplier'),
    });
    await tester.tap(find.byKey(const Key('btn_add_line')));
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 15));
    await driver.fillForm({
      'grn_line_product_0': const Select('QA Test Product'),
      'grn_line_qty_0': '100',
      'grn_line_rate_0': '10',
    });
    await driver.submit(saveButtonKey: 'btn_save');
    driver.expectNoErrorState();

    final grnHeader = await verifier.getOne(
      'rih_grn_headers',
      {'supplier_id': 'eq.${TestTenantConfig.supplierId}', 'order': 'created_at.desc', 'limit': '1'},
      select: 'grn_no,status',
    );
    expect(grnHeader['status'], 'DRAFT');

    await driver.approve(approveButtonKey: 'btn_approve');
    driver.expectNoErrorState();

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
  });
}
