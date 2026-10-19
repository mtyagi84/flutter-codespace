/// Product-picker dropdown search — a substring match across product
/// code, name, and EVERY barcode the product carries (its own base
/// barcode plus any configured pack-level ones, embedded as
/// `uoms: [{barcode: ...}, ...]` by whichever `getProductsForPicker`
/// query supplied the product map). Deliberately substring/contains,
/// unlike the dedicated barcode SCAN field's own exact-match-only lookup
/// (`getProductByBarcode`/`getProductByCode`, both `eq.` filters) — a
/// type-to-search dropdown is a different interaction (narrowing a
/// visible candidate list) from a physical-scanner field (resolving one
/// specific code to one specific product). See
/// project_barcode_feature_rework_2026_10_16 points 1 and 4.
///
/// `product` must have at least `product_code`/`product_name` (always
/// true for a product-picker row); `barcode` and `uoms` are read only if
/// present, so this is safe to call even against a product map that
/// hasn't been widened to carry them yet.
bool productMatchesBarcodeQuery(Map<String, dynamic> product, String query) {
  if ((product['product_code'] as String).toLowerCase().contains(query)) return true;
  if ((product['product_name'] as String).toLowerCase().contains(query)) return true;
  final baseBarcode = product['barcode'] as String?;
  if (baseBarcode != null && baseBarcode.toLowerCase().contains(query)) return true;
  final uoms = product['uoms'] as List<dynamic>? ?? const [];
  for (final u in uoms) {
    final bc = (u as Map<String, dynamic>)['barcode'] as String?;
    if (bc != null && bc.toLowerCase().contains(query)) return true;
  }
  return false;
}
