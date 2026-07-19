import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_presets.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../../../core/widgets/sakal_adaptive_list.dart';
import '../../../../core/widgets/sakal_field_card.dart';
import '../../data/models/product_model.dart';
import '../providers/products_providers.dart';

class ProductListScreen extends ConsumerStatefulWidget {
  const ProductListScreen({super.key});

  @override
  ConsumerState<ProductListScreen> createState() => _ProductListScreenState();
}

class _ProductListScreenState extends ConsumerState<ProductListScreen>
    with ScreenPermissionMixin<ProductListScreen> {
  @override
  String get screenName => RouteNames.productMaster;

  final _searchCtrl = TextEditingController();
  String  _search   = '';
  String? _nature;          // null = all
  bool?   _activeFilter;   // null = all

  List<ProductModel> _products  = [];
  bool    _loading   = true;
  bool    _loadingMore = false;
  bool    _hasMore   = true;
  String? _error;

  static const _pageSize = 50;
  int _offset = 0;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      final v = _searchCtrl.text.trim();
      if (v != _search) {
        _search = v;
        _reload();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    _offset   = 0;
    _hasMore  = true;
    _products = [];
    await _load();
  }

  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    if (mounted) setState(() { _loading = _offset == 0; _error = null; });
    try {
      final repo = ref.read(productsRepositoryProvider);
      final rows = await repo.getProducts(
        clientId:  session.clientId,
        companyId: session.companyId,
        search:    _search.isEmpty ? null : _search,
        nature:    _nature,
        isActive:  _activeFilter,
        limit:     _pageSize,
        offset:    _offset,
      );
      if (mounted) {
        setState(() {
          if (_offset == 0) {
            _products = rows;
          } else {
            _products = [..._products, ...rows];
          }
          _hasMore     = rows.length == _pageSize;
          _loading     = false;
          _loadingMore = false;
        });
      }
    } on DioException catch (e) {
      if (mounted) {
        setState(() {
          _loading     = false;
          _loadingMore = false;
          _error = e.response?.data?['message'] as String? ?? 'Failed to load products.';
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() { _loadingMore = true; });
    _offset += _pageSize;
    await _load();
  }

  void _openEntry({String? productId}) {
    context.push(RouteNames.productEntry,
        extra: productId != null ? {'productId': productId} : null);
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);

    return Column(
      children: [
        const OfflineBanner(),
        // ── Toolbar ──────────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Column(
            children: [
              Row(
                children: [
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Products',
                          style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary)),
                      Text('Product and item master',
                          style: TextStyle(
                              fontSize: 13, color: AppColors.textSecondary)),
                    ],
                  ),
                  const Spacer(),
                  if (!(session?.offlineMode ?? false) && canAdd)
                    FilledButton.icon(
                      onPressed: () => _openEntry(),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('New Product'),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              // Search + filters
              Row(
                children: [
                  Expanded(
                    child: SakalFieldCard(
                      label: 'Search',
                      editable: true,
                      child: TextField(
                        controller: _searchCtrl,
                        style: SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider)),
                        decoration: SakalFieldCard.bareDecoration.copyWith(
                          hintText: 'Search by code or name…',
                          hintStyle: const TextStyle(fontSize: 12, color: AppColors.textDisabled, fontWeight: FontWeight.normal),
                          prefixIcon: const Icon(Icons.search, size: 16),
                          suffixIcon: _search.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 16),
                                  onPressed: () { _searchCtrl.clear(); })
                              : null,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  _NatureFilter(
                    value: _nature,
                    onChanged: (v) { _nature = v; _reload(); },
                  ),
                  const SizedBox(width: 8),
                  _ActiveFilter(
                    value: _activeFilter,
                    onChanged: (v) { _activeFilter = v; _reload(); },
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Refresh',
                    icon: const Icon(Icons.refresh, size: 18),
                    onPressed: _loading ? null : _reload,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // ── Body ─────────────────────────────────────────────────────────────
        Expanded(
          child: _error != null
              ? _buildError()
              : Column(children: [
                  Expanded(
                    child: SakalAdaptiveList<ProductModel>(
                      loading: _loading,
                      error: null,
                      rows: _products,
                      columns: const [
                        SakalListColumn('Code', flex: 2),
                        SakalListColumn('Product Name', flex: 3),
                        SakalListColumn('Nature', flex: 2),
                        SakalListColumn('Category', flex: 2),
                        SakalListColumn('Base UOM', flex: 1),
                        SakalListColumn('Active', flex: 1),
                      ],
                      rowBuilder: (p, i) => _buildTableRow(p),
                      cardBuilder: (p) => _ProductCard(
                          product: p, onTap: () => _openEntry(productId: p.id)),
                      emptyState: _buildEmpty(),
                    ),
                  ),
                  if (_hasMore && !_loading)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: _loadingMore
                            ? const CircularProgressIndicator()
                            : OutlinedButton(
                                onPressed: _loadMore,
                                child: const Text('Load More'),
                              ),
                      ),
                    ),
                ]),
        ),
      ],
    );
  }

  Widget _buildError() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppColors.negative, size: 40),
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: AppColors.negative)),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      );

  Widget _buildEmpty() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.inventory_2_outlined,
                size: 48, color: AppColors.textSecondary),
            const SizedBox(height: 16),
            Text(
              _search.isNotEmpty || _nature != null || _activeFilter != null
                  ? 'No products match the current filter.'
                  : 'No products yet.',
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textSecondary),
            ),
            if (_search.isEmpty && _nature == null && canAdd) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => _openEntry(),
                icon: const Icon(Icons.add),
                label: const Text('Add First Product'),
              ),
            ],
          ],
        ),
      );

  // ── Desktop table row (SakalAdaptiveList owns the loading/error/empty +
  // mobile-card/desktop-table switch and its own header; this only builds
  // one row's content, matching the column flex spec passed to it) ────────

  Widget _buildTableRow(ProductModel p) => InkWell(
        onTap: () => _openEntry(productId: p.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                flex: 2,
                child: Text(p.productCode,
                    style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary)),
              ),
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.productName,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w500)),
                    if (p.shortName != null)
                      Text(p.shortName!,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.textSecondary)),
                  ],
                ),
              ),
              Expanded(flex: 2, child: _NatureBadge(p.productNature)),
              Expanded(
                flex: 2,
                child: Text(
                  p.categoryName ?? '—',
                  style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                ),
              ),
              Expanded(
                flex: 1,
                child: Text(p.baseUomName ?? '—', style: const TextStyle(fontSize: 13)),
              ),
              Expanded(
                flex: 1,
                child: Icon(
                  p.isActive ? Icons.check_circle_outline : Icons.cancel_outlined,
                  size: 18,
                  color: p.isActive ? AppColors.positive : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      );
}

// ── Mobile card ───────────────────────────────────────────────────────────────

class _ProductCard extends StatelessWidget {
  final ProductModel product;
  final VoidCallback onTap;
  const _ProductCard({required this.product, required this.onTap});

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                // Nature colour strip
                Container(
                  width: 4,
                  height: 52,
                  decoration: BoxDecoration(
                    color: _natureColor(product.productNature),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(product.productCode,
                              style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.primary)),
                          const SizedBox(width: 8),
                          _NatureBadge(product.productNature),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(product.productName,
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500)),
                      if (product.categoryName != null)
                        Text(product.categoryName!,
                            style: const TextStyle(
                                fontSize: 12,
                                color: AppColors.textSecondary)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right,
                    size: 20, color: AppColors.textSecondary),
              ],
            ),
          ),
        ),
      );

  static Color _natureColor(String nature) {
    switch (nature) {
      case 'SERVICE':       return AppColors.natureService;
      case 'RAW_MATERIAL':  return AppColors.natureRaw;
      case 'FINISHED_GOOD': return AppColors.positive;
      case 'PACKAGING':     return AppColors.naturePackaging;
      default:              return AppColors.primary;
    }
  }
}

// ── Nature badge ──────────────────────────────────────────────────────────────

class _NatureBadge extends StatelessWidget {
  final String nature;
  const _NatureBadge(this.nature);

  @override
  Widget build(BuildContext context) {
    final label = ProductModel.natureLabels[nature] ?? nature;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: _bg(),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: _fg())),
    );
  }

  Color _bg() {
    switch (nature) {
      case 'SERVICE':       return AppColors.natureServiceBg;
      case 'RAW_MATERIAL':  return AppColors.natureRawBg;
      case 'FINISHED_GOOD': return AppColors.natureFinishedBg;
      case 'PACKAGING':     return AppColors.naturePackagingBg;
      case 'CONSUMABLE':    return AppColors.natureConsumableBg;
      default:              return AppColors.surfaceVariant;
    }
  }

  Color _fg() {
    switch (nature) {
      case 'SERVICE':       return AppColors.natureService;
      case 'RAW_MATERIAL':  return AppColors.natureRaw;
      case 'FINISHED_GOOD': return AppColors.positive;
      case 'PACKAGING':     return AppColors.naturePackaging;
      case 'CONSUMABLE':    return AppColors.natureConsumable;
      default:              return AppColors.primary;
    }
  }
}

// ── Filter widgets ────────────────────────────────────────────────────────────

class _NatureFilter extends StatelessWidget {
  final String?               value;
  final ValueChanged<String?> onChanged;
  const _NatureFilter({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => DropdownButtonHideUnderline(
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: DropdownButton<String?>(
            value:    value,
            hint:     const Text('All Types',
                          style: TextStyle(fontSize: 13)),
            isDense:  true,
            onChanged: onChanged,
            items: [
              const DropdownMenuItem(value: null, child: Text('All Types')),
              ...ProductModel.natureLabels.entries.map((e) =>
                  DropdownMenuItem(value: e.key, child: Text(e.value))),
            ],
          ),
        ),
      );
}

class _ActiveFilter extends StatelessWidget {
  final bool?               value;
  final ValueChanged<bool?> onChanged;
  const _ActiveFilter({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => DropdownButtonHideUnderline(
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: DropdownButton<bool?>(
            value:    value,
            isDense:  true,
            onChanged: onChanged,
            items: const [
              DropdownMenuItem(value: null,  child: Text('All Status')),
              DropdownMenuItem(value: true,  child: Text('Active')),
              DropdownMenuItem(value: false, child: Text('Inactive')),
            ],
          ),
        ),
      );
}
