import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../sales/presentation/providers/sales_invoice_providers.dart';
import '../widgets/pos_keyboard.dart';

/// Manual product discovery — a SEPARATE screen from Price Check (which
/// stays scan-only), for a cashier who needs to find something by browsing
/// or typing a partial name/code rather than knowing a barcode already.
/// Pushed with `Navigator.push` (not a go_router route — always reached from
/// within an active New Sale cart, never deep-linked) and returns the picked
/// product map via `Navigator.pop(context, product)`, shaped identically to
/// `getProductsForPicker`'s own rows so the caller can feed it straight into
/// its existing `_addProduct(...)`.
///
/// The keyboard is an ALWAYS-VISIBLE part of this page's own layout, pinned
/// at the bottom above a live-updating result grid — never a popup sheet on
/// top of an already-full-screen page (found live: stacking a keyboard
/// bottom-sheet on top of this screen looked broken and hid the very field
/// being typed into). Typing "coc" filters the grid to every matching
/// product as each keystroke lands, same as the Credit checkout screen's
/// own customer search.
class PosBrowseProductsScreen extends ConsumerStatefulWidget {
  final String? customerId;
  final String localCurrency;

  const PosBrowseProductsScreen({super.key, this.customerId, required this.localCurrency});

  @override
  ConsumerState<PosBrowseProductsScreen> createState() => _PosBrowseProductsScreenState();
}

class _PosBrowseProductsScreenState extends ConsumerState<PosBrowseProductsScreen> {
  // Breadcrumb trail of categories drilled into so far — [] means the
  // top level (no category picked yet).
  final List<Map<String, dynamic>> _trail = [];
  bool _loading = true;
  List<Map<String, dynamic>> _categories = [];
  List<Map<String, dynamic>> _products = [];
  String _query = '';
  bool _shift = false;
  Timer? _debounce;

  // Keyed by product id — resolved once a product list is shown, never for
  // category tiles. Null means "not configured" (shown as "No price" and
  // left unselectable, consistent with New Sale's own no-price-no-invoice
  // rule — see `_addProduct`'s own guard).
  final Map<String, double?> _prices = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    setState(() => _loading = true);
    try {
      final parentId = _trail.isEmpty ? null : _trail.last['id'] as String;
      final catRes = await DioClient.instance.get('/rim_item_categories', queryParameters: {
        'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
        'is_active': 'eq.true', 'is_deleted': 'eq.false',
        'parent_id': parentId == null ? 'is.null' : 'eq.$parentId',
        'select': 'id,category_name', 'order': 'sort_order.asc,category_name.asc',
      });
      final categories = List<Map<String, dynamic>>.from(catRes.data as List);

      // A category with no children is a LEAF — show its products instead
      // of an empty tile grid. `category_id` is the product's own single
      // (leaf) category FK, so a plain equality filter is correct here —
      // no need for the recursive fn_category_subtree used by reports,
      // since we only ever reach this branch once we're already at a leaf.
      List<Map<String, dynamic>> products = [];
      if (categories.isEmpty && parentId != null) {
        final prodRes = await DioClient.instance.get('/rim_products', queryParameters: {
          'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
          'category_id': 'eq.$parentId', 'is_active': 'eq.true', 'is_deleted': 'eq.false',
          'select': 'id,product_code,product_name,base_uom_id,tracking_type,sales_tax_group_id,'
              'uom:rim_common_masters!base_uom_id(description)',
          'order': 'product_name.asc', 'limit': '200',
        });
        products = List<Map<String, dynamic>>.from(prodRes.data as List);
      }

      if (mounted) setState(() { _categories = categories; _products = products; _loading = false; });
      if (products.isNotEmpty) _loadPrices(products);
    } catch (_) {
      if (mounted) setState(() { _categories = []; _products = []; _loading = false; });
    }
  }

  Future<void> _searchByName(String name) async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _categories = []; });
    try {
      final res = await DioClient.instance.get('/rim_products', queryParameters: {
        'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
        'is_active': 'eq.true', 'is_deleted': 'eq.false',
        'or': '(product_code.ilike.*$name*,product_name.ilike.*$name*)',
        'select': 'id,product_code,product_name,base_uom_id,tracking_type,sales_tax_group_id,'
            'uom:rim_common_masters!base_uom_id(description)',
        'order': 'product_name.asc', 'limit': '200',
      });
      final products = List<Map<String, dynamic>>.from(res.data as List);
      if (mounted) setState(() { _products = products; _loading = false; });
      if (products.isNotEmpty) _loadPrices(products);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// One parallel batch of `fn_get_active_price` calls for whatever's
  /// currently on screen (never more than 200 rows, the same cap every
  /// product picker in this app already uses) — there's no bulk-price RPC
  /// in this schema, so this is the same per-row call New Sale's own
  /// `_addProduct` makes, just fanned out concurrently instead of one at a
  /// time, and only for products actually visible right now.
  Future<void> _loadPrices(List<Map<String, dynamic>> products) async {
    final session = ref.read(sessionProvider)!;
    final locationId = session.locationId;
    if (locationId == null || locationId.isEmpty) return;
    final ds = ref.read(salesInvoiceRepositoryProvider);
    final today = _today();
    await Future.wait(products.map((p) async {
      try {
        final price = await ds.getActivePrice(
          clientId: session.clientId, companyId: session.companyId, locationId: locationId,
          productId: p['id'] as String, uomId: p['base_uom_id'] as String,
          customerId: widget.customerId ?? '', asOfDate: today, currencyCode: widget.localCurrency,
        );
        final rate = (price?['selling_price'] as num?)?.toDouble();
        if (mounted) setState(() => _prices[p['id'] as String] = (rate != null && rate > 0) ? rate : null);
      } catch (_) {
        if (mounted) setState(() => _prices[p['id'] as String] = null);
      }
    }));
  }

  String _today() {
    final d = DateTime.now();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  void _drillInto(Map<String, dynamic> category) {
    setState(() { _trail.add(category); _query = ''; });
    _load();
  }

  void _jumpTo(int index) {
    // index == -1 means "Home" (clear the whole trail).
    setState(() {
      if (index < 0) {
        _trail.clear();
      } else {
        _trail.removeRange(index + 1, _trail.length);
      }
      _query = '';
    });
    _load();
  }

  void _onQueryChanged(String q) {
    setState(() => _query = q);
    _debounce?.cancel();
    if (q.isEmpty) {
      _jumpTo(_trail.length - 1);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () => _searchByName(q));
  }

  void _type(String ch) => _onQueryChanged(_query + (_shift ? ch.toUpperCase() : ch));
  void _space() => _onQueryChanged('$_query ');
  void _backspace() {
    if (_query.isEmpty) return;
    _onQueryChanged(_query.substring(0, _query.length - 1));
  }

  void _selectProduct(Map<String, dynamic> product) {
    // No price, no invoice — same rule New Sale's own _addProduct enforces;
    // checked here too so a cashier never even gets the impression tapping
    // an unpriced tile "worked" before being bounced back by the cart.
    if (_prices[product['id']] == null) return;
    Navigator.of(context).pop(product);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary, foregroundColor: Colors.white,
        title: const Text('Search Products'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
            child: Row(children: [
              const Icon(Icons.search, size: 18, color: AppColors.textSecondary),
              const SizedBox(width: 8),
              Expanded(child: Text(_query.isEmpty ? 'Type to search by name or code…' : _query, style: TextStyle(fontSize: 15, color: _query.isEmpty ? AppColors.textSecondary : AppColors.textPrimary))),
              if (_query.isNotEmpty)
                IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => _onQueryChanged(''), padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 28, minHeight: 28)),
            ]),
          ),
        ),
        if (_query.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SizedBox(
              height: 32,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                _Crumb(label: 'Home', onTap: () => _jumpTo(-1), active: _trail.isEmpty),
                for (var i = 0; i < _trail.length; i++)
                  _Crumb(label: _trail[i]['category_name'] as String, onTap: () => _jumpTo(i), active: i == _trail.length - 1),
              ]),
            ),
          ),
        const SizedBox(height: 8),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _categories.isNotEmpty
                  ? GridView.builder(
                      padding: const EdgeInsets.all(12),
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 160, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 1.1),
                      itemCount: _categories.length,
                      itemBuilder: (context, i) => _CategoryTile(category: _categories[i], onTap: () => _drillInto(_categories[i])),
                    )
                  : _products.isEmpty
                      ? const Center(child: Text('No products here.', style: TextStyle(color: AppColors.textSecondary)))
                      : GridView.builder(
                          padding: const EdgeInsets.all(12),
                          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 180, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 1.15),
                          itemCount: _products.length,
                          itemBuilder: (context, i) {
                            final p = _products[i];
                            final hasPrice = _prices.containsKey(p['id']);
                            return _ProductTile(
                              product: p,
                              price: _prices[p['id']],
                              priceLoaded: hasPrice,
                              currency: widget.localCurrency,
                              onTap: () => _selectProduct(p),
                            );
                          },
                        ),
        ),
        // ALWAYS part of this page — never a popup on top of it.
        Padding(
          padding: const EdgeInsets.all(10),
          child: PosKeyboardKeys(shift: _shift, onType: _type, onSpace: _space, onBackspace: _backspace, onToggleShift: () => setState(() => _shift = !_shift)),
        ),
      ]),
    );
  }
}

class _Crumb extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool active;
  const _Crumb({required this.label, required this.onTap, required this.active});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: active ? AppColors.primary.withValues(alpha: 0.12) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Text(label, style: TextStyle(fontSize: 12.5, fontWeight: active ? FontWeight.w800 : FontWeight.w500, color: active ? AppColors.primary : AppColors.textSecondary)),
        ),
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  final Map<String, dynamic> category;
  final VoidCallback onTap;
  const _CategoryTile({required this.category, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
          padding: const EdgeInsets.all(10),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.category_outlined, size: 30, color: AppColors.primary),
            const SizedBox(height: 8),
            Text(category['category_name'] as String, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          ]),
        ),
      ),
    );
  }
}

class _ProductTile extends StatelessWidget {
  final Map<String, dynamic> product;
  final double? price;
  final bool priceLoaded;
  final String currency;
  final VoidCallback onTap;
  const _ProductTile({required this.product, required this.price, required this.priceLoaded, required this.currency, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final uomLabel = (product['uom'] as Map<String, dynamic>?)?['description'] as String? ?? '';
    final noPrice = priceLoaded && price == null;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: noPrice ? null : onTap,
        child: Opacity(
          opacity: noPrice ? 0.5 : 1,
          child: Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
            padding: const EdgeInsets.all(10),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.inventory_2_outlined, size: 24, color: AppColors.secondary),
              const SizedBox(height: 6),
              Text(product['product_name'] as String, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              Text('${product['product_code']} · $uomLabel', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, color: AppColors.textSecondary)),
              const SizedBox(height: 4),
              if (!priceLoaded)
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              else if (noPrice)
                const Text('No price', style: TextStyle(fontSize: 11, color: AppColors.negative, fontWeight: FontWeight.w700))
              else
                Text('${price!.toStringAsFixed(2)} $currency', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.primary)),
            ]),
          ),
        ),
      ),
    );
  }
}
