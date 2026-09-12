/// Reads the QA Automation tenant's identity out of --dart-define values —
/// never hardcoded/committed, per the approved E2E test automation plan.
///
/// Populate these after running `sakal/backend/scripts/seed_qa_master_data.sql`
/// (it RAISE NOTICEs every value below at the end of that script) and pass
/// them at test-run time, e.g.:
///
///   flutter test integration_test/flows/grn_to_sales_invoice_pilot_test.dart \
///     -d web-server \
///     --dart-define=QA_CLIENT_NO=SK-12345 \
///     --dart-define=QA_USERNAME=qa_admin \
///     --dart-define=QA_PASSWORD='the real password you set in the seed script' \
///     --dart-define=QA_LOCATION_ID=... \
///     --dart-define=QA_PRODUCT_ID=... \
///     --dart-define=QA_CUSTOMER_ID=... \
///     --dart-define=QA_SUPPLIER_ID=...
///
/// company_id/user_id are NOT listed here — fn_login's own response already
/// returns both, so BackendVerifier reads them off the login result instead
/// of needing a second, redundant source of truth.
class TestTenantConfig {
  // fn_login's p_client_no argument — the "SK-XXXXX" printed by the seed
  // script, NOT the client_id UUID.
  static const clientNo = String.fromEnvironment('QA_CLIENT_NO');
  static const username = String.fromEnvironment('QA_USERNAME');
  static const password = String.fromEnvironment('QA_PASSWORD');

  // Printed by the seed script — not derivable from a login response.
  static const locationId = String.fromEnvironment('QA_LOCATION_ID');
  static const productId  = String.fromEnvironment('QA_PRODUCT_ID');
  static const customerId = String.fromEnvironment('QA_CUSTOMER_ID');
  static const supplierId = String.fromEnvironment('QA_SUPPLIER_ID');

  static void assertConfigured() {
    final missing = <String>[
      if (clientNo.isEmpty) 'QA_CLIENT_NO',
      if (username.isEmpty) 'QA_USERNAME',
      if (password.isEmpty) 'QA_PASSWORD',
      if (locationId.isEmpty) 'QA_LOCATION_ID',
      if (productId.isEmpty) 'QA_PRODUCT_ID',
      if (customerId.isEmpty) 'QA_CUSTOMER_ID',
      if (supplierId.isEmpty) 'QA_SUPPLIER_ID',
    ];
    if (missing.isNotEmpty) {
      throw StateError(
        'Missing --dart-define values for: ${missing.join(', ')}. '
        'Run seed_qa_master_data.sql first and pass its printed IDs — see '
        'this file\'s own doc comment for the exact flutter test invocation.',
      );
    }
  }
}
