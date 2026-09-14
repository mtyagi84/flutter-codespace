import 'backend_verifier.dart';
import 'test_tenant_config.dart';

/// Fetches reference IDs shared by most backend-RPC test files (product's
/// UOM, base currency's `rim_currencies.id` surrogate key) — pulled out
/// once here instead of re-querying identically in every
/// `test/backend/*_backend_test.dart` file. Call `CommonRefs.load(verifier)`
/// once in a `setUpAll`.
class CommonRefs {
  final String uomId;
  final String currencyId; // rim_currencies.id (UUID), not the ISO code

  CommonRefs._(this.uomId, this.currencyId);

  static Future<CommonRefs> load(BackendVerifier verifier) async {
    final product = await verifier.getOne(
      'rim_products',
      {'id': 'eq.${TestTenantConfig.productId}'},
      select: 'base_uom_id',
    );
    final currency = await verifier.getOne(
      'rim_currencies',
      {'currency_id': 'eq.USD'},
      select: 'id',
    );
    return CommonRefs._(
      product['base_uom_id'] as String,
      currency['id'] as String,
    );
  }
}
