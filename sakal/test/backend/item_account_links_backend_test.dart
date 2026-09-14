import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level CRUD test for MST-IAL (Item Account Links) — the last of
/// the 34 Master screens in the test plan. Per-product override of the
/// company/category/location-level account link resolved by
/// rim_account_link_setup (already exercised indirectly all session via
/// CommonRefs' ensure*AccountLink() helpers, and directly by
/// finance_masters_backend_test.dart's MST-ALS notes). This table
/// (rim_account_links) is the ITEM-granularity override layer on top of
/// that mechanism.
void main() {
  late BackendVerifier verifier;

  setUpAll(() async {
    verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);

    // UNIQUE(client_id, company_id, link_type_id, product_id) is plain, not
    // partial on is_deleted — a soft-delete alone won't free the key for a
    // fresh insert on re-run, so hard-delete any leftover row instead.
    await verifier.delete('rim_account_links', {'product_id': 'eq.${TestTenantConfig.productId}'});
  });

  test('MST-IAL Item Account Links: create a per-product STOCK_ACCOUNT override, read, update round-trip', () async {
    final linkType = (await verifier.getUnscoped(
      'rim_account_link_types',
      {'link_key': 'eq.STOCK_ACCOUNT'},
      select: 'id',
    )).first;

    final created = await verifier.insert('rim_account_links', {
      'link_type_id': linkType['id'],
      'link_type': 'ITEM',
      'product_id': TestTenantConfig.productId,
      'account_id': TestTenantConfig.stockAccountId,
      'is_deleted': false,
    });
    expect(created['client_id'], verifier.clientId);
    expect(created['link_type'], 'ITEM');

    final read = await verifier.getOne(
      'rim_account_links',
      {'id': 'eq.${created['id']}'},
      select: 'account_id',
    );
    expect(read['account_id'], TestTenantConfig.stockAccountId);

    // Update = re-point the override at a different account (a real GL
    // account, not a throwaway id — "Trade Payables" group works fine here
    // since this test only checks the column round-trips, not GL validity).
    final altAccount = await verifier.getOne('rim_accounts', {'account_code': 'eq.2110'}, select: 'id');
    await verifier.patch('rim_account_links', {'id': 'eq.${created['id']}'}, {'account_id': altAccount['id']});
    final afterPatch = await verifier.getOne('rim_account_links', {'id': 'eq.${created['id']}'}, select: 'account_id');
    expect(afterPatch['account_id'], altAccount['id']);

    // Hard-delete cleanup (see setUpAll's own comment) — a lingering ITEM
    // override on the shared QA_PROD-001 fixture product would silently
    // change which account every OTHER test file's stock postings resolve to.
    await verifier.delete('rim_account_links', {'id': 'eq.${created['id']}'});
  });
}
