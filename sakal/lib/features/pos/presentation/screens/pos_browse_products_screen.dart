import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../widgets/pos_keyboard.dart';

/// Manual product discovery via category drill-down — a SEPARATE screen
/// from Price Check (which stays scan-only), for the case a cashier needs
/// to find something by browsing rather than knowing a barcode/SKU already.
/// Pushed with `Navigator.push` (not a go_router route — always reached from
/// within an active New Sale cart, never deep-linked) and returns the picked
/// product map via `Navigator.pop(context, product)`, shaped identically to
/// `getProductsForPicker`'s own rows so the caller can feed it straight into
/// its existing `_addProduct(...)`.
class PosBrowseProductsScreen extends ConsumerStatefulWidget {
  const PosBrowseProductsScreen({super.key});

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
  String _nameFilter = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
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
      if (mounted) setState(() { _products = List<Map<String, dynamic>>.from(res.data as List); _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _drillInto(Map<String, dynamic> category) {
    setState(() { _trail.add(category); _nameFilter = ''; });
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
      _nameFilter = '';
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary, foregroundColor: Colors.white,
        title: const Text('Browse Products'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: PosKeyboardField(
            label: 'Search by name or code (skips category browsing)',
            value: _nameFilter,
            onChanged: (v) {
              setState(() => _nameFilter = v);
              if (v.isEmpty) {
                _jumpTo(_trail.length - 1);
              } else {
                _searchByName(v);
              }
            },
          ),
        ),
        if (_nameFilter.isEmpty)
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
                          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 180, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 1.3),
                          itemCount: _products.length,
                          itemBuilder: (context, i) => _ProductTile(product: _products[i], onTap: () => Navigator.of(context).pop(_products[i])),
                        ),
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
  final VoidCallback onTap;
  const _ProductTile({required this.product, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final uomLabel = (product['uom'] as Map<String, dynamic>?)?['description'] as String? ?? '';
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
          padding: const EdgeInsets.all(10),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.inventory_2_outlined, size: 26, color: AppColors.secondary),
            const SizedBox(height: 8),
            Text(product['product_name'] as String, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            Text('${product['product_code']} · $uomLabel', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, color: AppColors.textSecondary)),
          ]),
        ),
      ),
    );
  }
}
