import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../data/models/item_category_model.dart';
import '../providers/item_categories_providers.dart';

/// Per-item view/override of every GL account link (Sales, COGS, Stock,
/// Purchase Accrual, …) for one product. Writes directly into
/// rim_account_links (the same lazy cache fn_resolve_account_link reads
/// from) — since the resolver checks the cache first, this is exactly a
/// per-item override regardless of whatever Company/Category/Location
/// level the general setup uses for that account type.
/// See backend/migrations/032_account_link_setup.sql.
class ItemAccountLinksScreen extends ConsumerStatefulWidget {
  const ItemAccountLinksScreen({super.key});

  @override
  ConsumerState<ItemAccountLinksScreen> createState() => _ItemAccountLinksScreenState();
}

class _ItemAccountLinksScreenState extends ConsumerState<ItemAccountLinksScreen>
    with ScreenPermissionMixin<ItemAccountLinksScreen> {
  @override String get screenName => RouteNames.itemAccountLinks;

  List<Map<String, dynamic>> _products  = [];
  List<ItemCategoryModel>    _categories = [];
  List<Map<String, dynamic>> _linkTypes  = [];
  String? _categoryFilter;
  final _searchCtrl = TextEditingController();
  String _search = '';

  bool    _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() => setState(() => _search = _searchCtrl.text.trim().toLowerCase()));
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        DioClient.instance.get('/rim_products', queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'is_active':  'eq.true',
          'is_deleted': 'eq.false',
          'select':     'id,product_code,product_name,category_id',
          'order':      'product_name.asc',
          'limit':      '2000',
        }),
        DioClient.instance.get('/rim_account_link_types', queryParameters: {
          'is_deleted': 'eq.false',
          'is_active':  'eq.true',
          'select':     'id,link_key,link_name,sort_order',
          'order':      'sort_order.asc',
        }),
      ]);
      final categories = await ref.read(itemCategoriesRepositoryProvider).getCategories(
          clientId: session.clientId, companyId: session.companyId);
      if (!mounted) return;
      setState(() {
        _products   = List<Map<String, dynamic>>.from(results[0].data as List);
        _linkTypes  = List<Map<String, dynamic>>.from(results[1].data as List);
        _categories = categories;
        _loading    = false;
      });
    } on DioException {
      if (mounted) setState(() { _loading = false; _error = 'Could not load items.'; });
    }
  }

  // Category filter + all its descendants, computed from the already-loaded
  // flat category list (same tree fn_category_subtree walks server-side).
  Set<String> _categoryAndDescendants(String categoryId) {
    final result = <String>{categoryId};
    bool grew = true;
    while (grew) {
      grew = false;
      for (final c in _categories) {
        if (c.id != null && c.parentId != null && result.contains(c.parentId) && !result.contains(c.id)) {
          result.add(c.id!);
          grew = true;
        }
      }
    }
    return result;
  }

  String _categoryPath(ItemCategoryModel c) {
    final byId = {for (final cat in _categories) if (cat.id != null) cat.id!: cat};
    String pathOf(ItemCategoryModel cat) {
      if (cat.parentId == null) return cat.categoryName;
      final p = byId[cat.parentId];
      return p == null ? cat.categoryName : '${pathOf(p)} › ${cat.categoryName}';
    }
    return pathOf(c);
  }

  List<Map<String, dynamic>> get _filteredProducts {
    Set<String>? allowedCategories;
    if (_categoryFilter != null) allowedCategories = _categoryAndDescendants(_categoryFilter!);
    return _products.where((p) {
      if (allowedCategories != null && !allowedCategories.contains(p['category_id'])) return false;
      if (_search.isEmpty) return true;
      final code = (p['product_code'] as String? ?? '').toLowerCase();
      final name = (p['product_name'] as String? ?? '').toLowerCase();
      return code.contains(_search) || name.contains(_search);
    }).toList();
  }

  void _openItem(Map<String, dynamic> product) {
    final offline = ref.read(sessionProvider)?.offlineMode ?? false;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ItemAccountLinksDialog(
          product: product, linkTypes: _linkTypes, canEdit: canEdit, offline: offline),
    ).then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    final offline  = ref.watch(sessionProvider)?.offlineMode ?? false;
    final isMobile = Responsive.isMobile(context);
    final filtered = _filteredProducts;
    return SingleChildScrollView(
      padding: EdgeInsets.all(isMobile ? 16 : 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Item Account Links',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              const SizedBox(height: 4),
              const Text('View or override which GL account each posting type uses for a specific item.',
                  style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
              const SizedBox(height: 20),

              if (offline) const OfflineBanner(),
              if (offline) const SizedBox(height: 16),

              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.negative.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.negative.withValues(alpha: 0.3)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.error_outline, color: AppColors.negative, size: 18),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_error!, style: const TextStyle(fontSize: 13, color: AppColors.negative))),
                    TextButton(onPressed: _load, child: const Text('Retry')),
                  ]),
                ),
                const SizedBox(height: 20),
              ],

              if (_loading)
                const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
              else ...[
                if (isMobile)
                  Column(children: [
                    _categoryFilterField(),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _searchCtrl,
                      decoration: const InputDecoration(
                          labelText: 'Search item code or name', prefixIcon: Icon(Icons.search)),
                    ),
                  ])
                else
                  Row(children: [
                    Expanded(flex: 2, child: _categoryFilterField()),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _searchCtrl,
                        decoration: const InputDecoration(
                            labelText: 'Search item code or name', prefixIcon: Icon(Icons.search)),
                      ),
                    ),
                  ]),
                const SizedBox(height: 16),

                Card(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: filtered.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(40),
                          child: Center(child: Text('No items match this filter.', style: TextStyle(color: AppColors.textSecondary))),
                        )
                      : Column(
                          children: filtered.map((p) => ListTile(
                            minVerticalPadding: 16,
                            title: Text('${p['product_code']} — ${p['product_name']}',
                                style: const TextStyle(fontSize: 13)),
                            trailing: const Icon(Icons.chevron_right, size: 18),
                            onTap: () => _openItem(p),
                          )).toList(),
                        ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _categoryFilterField() {
    final options = _categories.where((c) => c.id != null).toList();
    final selected = options.where((c) => c.id == _categoryFilter).toList();
    return Autocomplete<ItemCategoryModel>(
      key: ValueKey(_categoryFilter ?? 'none'),
      initialValue: TextEditingValue(text: selected.isNotEmpty ? _categoryPath(selected.first) : ''),
      optionsBuilder: (v) {
        final q = v.text.toLowerCase().trim();
        if (q.isEmpty) return options;
        return options.where((c) => _categoryPath(c).toLowerCase().contains(q));
      },
      displayStringForOption: _categoryPath,
      onSelected: (c) => setState(() => _categoryFilter = c.id),
      fieldViewBuilder: (context, textCtrl, focusNode, onFieldSubmitted) => TextFormField(
        controller: textCtrl,
        focusNode: focusNode,
        onChanged: (v) { if (v.isEmpty) setState(() => _categoryFilter = null); },
        decoration: InputDecoration(
          labelText: 'Filter by category',
          prefixIcon: const Icon(Icons.category_outlined),
          suffixIcon: _categoryFilter != null
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () { textCtrl.clear(); setState(() => _categoryFilter = null); },
                )
              : null,
        ),
      ),
      optionsViewBuilder: (context, onSel, opts) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(4),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240, maxWidth: 400),
            child: ListView.builder(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              itemCount: opts.length,
              itemBuilder: (context, idx) {
                final c = opts.elementAt(idx);
                return InkWell(
                  onTap: () => onSel(c),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Text(_categoryPath(c), style: const TextStyle(fontSize: 13)),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

// ── Per-item account links dialog ───────────────────────────────────────────

class _ItemAccountLinksDialog extends ConsumerStatefulWidget {
  final Map<String, dynamic> product;
  final List<Map<String, dynamic>> linkTypes;
  final bool canEdit;
  final bool offline;
  const _ItemAccountLinksDialog({
    required this.product,
    required this.linkTypes,
    required this.canEdit,
    required this.offline,
  });

  @override
  ConsumerState<_ItemAccountLinksDialog> createState() => _ItemAccountLinksDialogState();
}

class _ItemAccountLinksDialogState extends ConsumerState<_ItemAccountLinksDialog> {
  // link_type_id -> {cacheId, accountId}
  final Map<String, Map<String, dynamic>> _rows = {};
  final Map<String, String?> _original = {};
  bool _loading = true;
  bool _saving  = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  static String _sourceLabel(String? linkType) => switch (linkType) {
    'ITEM'     => 'Override',
    'COMPANY'  => 'Company default',
    'CATEGORY' => 'Category default',
    'LOCATION' => 'Location default',
    _          => 'Not configured',
  };

  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      final cacheRes = await DioClient.instance.get('/rim_account_links', queryParameters: {
        'client_id':  'eq.${session.clientId}',
        'company_id': 'eq.${session.companyId}',
        'product_id': 'eq.${widget.product['id']}',
        'is_deleted': 'eq.false',
        'select':     'id,link_type_id,link_type,account_id',
      });
      final cached = List<Map<String, dynamic>>.from(cacheRes.data as List);
      var cachedByType = {for (final r in cached) r['link_type_id'] as String: r};

      final toResolve = widget.linkTypes.where((t) => !cachedByType.containsKey(t['id'])).toList();
      if (toResolve.isNotEmpty) {
        await Future.wait(toResolve.map((t) => DioClient.instance.post(
            '/rpc/fn_resolve_account_link', data: {
          'p_client_id':   session.clientId,
          'p_company_id':  session.companyId,
          'p_location_id': session.locationId,
          'p_product_id':  widget.product['id'],
          'p_link_key':    t['link_key'],
        })));
        // Freshly resolved types are now cached — re-fetch once to pick up
        // their link_type (source) alongside the account, in one shot.
        final refreshed = await DioClient.instance.get('/rim_account_links', queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'product_id': 'eq.${widget.product['id']}',
          'is_deleted': 'eq.false',
          'select':     'id,link_type_id,link_type,account_id',
        });
        final refreshedRows = List<Map<String, dynamic>>.from(refreshed.data as List);
        cachedByType = {for (final r in refreshedRows) r['link_type_id'] as String: r};
      }

      if (!mounted) return;
      setState(() {
        for (final t in widget.linkTypes) {
          final id = t['id'] as String;
          final cachedRow = cachedByType[id];
          _rows[id] = {
            'cacheId':   cachedRow?['id'],
            'accountId': cachedRow?['account_id'],
            'source':    cachedRow?['link_type'] as String?,
          };
          _original[id] = _rows[id]!['accountId'] as String?;
        }
        _loading = false;
      });
    } on DioException {
      if (mounted) setState(() { _loading = false; _error = 'Could not load account links for this item.'; });
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppColors.negative));
  }

  Future<void> _save() async {
    final session = ref.read(sessionProvider)!;
    setState(() => _saving = true);
    try {
      for (final t in widget.linkTypes) {
        final id = t['id'] as String;
        final row = _rows[id]!;
        final accountId = row['accountId'] as String?;
        if (accountId == null || accountId == _original[id]) continue;
        if (row['cacheId'] != null) {
          await DioClient.instance.patch('/rim_account_links',
              queryParameters: {'id': 'eq.${row['cacheId']}'},
              data: {'account_id': accountId, 'link_type': 'ITEM', 'link_key_id': widget.product['id']},
              options: Options(headers: {'Prefer': 'return=minimal'}));
        } else {
          await DioClient.instance.post('/rim_account_links', data: {
            'client_id': session.clientId, 'company_id': session.companyId,
            'link_type_id': id, 'link_type': 'ITEM', 'link_key_id': widget.product['id'],
            'product_id': widget.product['id'], 'account_id': accountId,
            'created_by': session.userId,
          }, options: Options(headers: {'Prefer': 'return=minimal'}));
        }
      }
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    } on DioException catch (e) {
      if (mounted) { setState(() => _saving = false); _showError(e.response?.data?['message'] as String? ?? 'Save failed.'); }
    }
  }

  String _displayAccount(Map<String, dynamic> a) => '[${a['account_code']}] ${a['account_name']}';

  @override
  Widget build(BuildContext context) {
    final accountsAsync = ref.watch(accountsProvider);
    final isMobile = Responsive.isMobile(context);
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: EdgeInsets.symmetric(horizontal: isMobile ? 16 : 40, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 640),
        child: Padding(
          padding: EdgeInsets.all(isMobile ? 18 : 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Text('${widget.product['product_code']} — ${widget.product['product_name']}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                ),
                IconButton(icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context, rootNavigator: true).pop()),
              ]),
              const Text('Account links for this item — overrides the general Company/Category/Location setup.',
                  style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              const SizedBox(height: 12),
              if (widget.offline) const OfflineBanner(),
              if (widget.offline) const SizedBox(height: 12),

              if (_error != null) ...[
                Text(_error!, style: const TextStyle(fontSize: 12, color: AppColors.negative)),
                const SizedBox(height: 12),
              ],

              if (_loading)
                const Expanded(child: Center(child: CircularProgressIndicator()))
              else
                Expanded(
                  child: accountsAsync.when(
                    loading: () => const Center(child: CircularProgressIndicator()),
                    error: (e, _) => Text('Could not load accounts: $e', style: const TextStyle(fontSize: 12, color: AppColors.negative)),
                    data: (accounts) => SingleChildScrollView(
                      child: Column(
                        children: widget.linkTypes.map((t) {
                          final id = t['id'] as String;
                          final row = _rows[id]!;
                          final accountId = row['accountId'] as String?;
                          final matches = accounts.where((a) => a['id'] == accountId).toList();
                          final selected = matches.isNotEmpty ? matches.first : null;
                          final picker = Autocomplete<Map<String, dynamic>>(
                            key: ValueKey('${id}_${accountId ?? 'none'}'),
                            initialValue: TextEditingValue(text: selected != null ? _displayAccount(selected) : ''),
                            optionsBuilder: (v) {
                              final q = v.text.toLowerCase().trim();
                              final filtered = q.isEmpty
                                  ? accounts
                                  : accounts.where((a) =>
                                      (a['account_code'] as String? ?? '').toLowerCase().contains(q) ||
                                      (a['account_name']  as String? ?? '').toLowerCase().contains(q));
                              return filtered.take(50);
                            },
                            displayStringForOption: _displayAccount,
                            fieldViewBuilder: (context, textCtrl, focusNode, onFieldSubmitted) => TextFormField(
                              controller: textCtrl,
                              focusNode: focusNode,
                              enabled: widget.canEdit && !widget.offline && !_saving,
                              decoration: const InputDecoration(isDense: true, hintText: 'Not configured'),
                              style: const TextStyle(fontSize: 13),
                            ),
                            onSelected: (a) => setState(() => _rows[id] = {...row, 'accountId': a['id'], 'source': 'ITEM'}),
                            optionsViewBuilder: (context, onSel, options) => Align(
                              alignment: Alignment.topLeft,
                              child: Material(
                                elevation: 4,
                                borderRadius: BorderRadius.circular(4),
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(maxHeight: 240, maxWidth: 360),
                                  child: ListView.builder(
                                    padding: EdgeInsets.zero,
                                    shrinkWrap: true,
                                    itemCount: options.length,
                                    itemBuilder: (context, idx) {
                                      final a = options.elementAt(idx);
                                      return InkWell(
                                        onTap: () => onSel(a),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                          child: Text(_displayAccount(a), style: const TextStyle(fontSize: 13)),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
                          );
                          final badge = Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                            decoration: BoxDecoration(
                              color: (row['source'] == 'ITEM' ? AppColors.secondary : AppColors.textDisabled)
                                  .withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(_sourceLabel(row['source'] as String?),
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                                    color: row['source'] == 'ITEM' ? AppColors.secondary : AppColors.textSecondary)),
                          );
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: isMobile
                                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Row(children: [
                                      Expanded(child: Text(t['link_name'] ?? '', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                                      badge,
                                    ]),
                                    const SizedBox(height: 4),
                                    picker,
                                  ])
                                : Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                                    Expanded(flex: 2, child: Text(t['link_name'] ?? '', style: const TextStyle(fontSize: 13))),
                                    Expanded(flex: 3, child: picker),
                                    const SizedBox(width: 8),
                                    SizedBox(width: 90, child: badge),
                                  ]),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 16),

              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(
                    onPressed: _saving ? null : () => Navigator.of(context, rootNavigator: true).pop(),
                    child: const Text('Cancel')),
                const SizedBox(width: 12),
                SizedBox(
                  width: 120,
                  child: ElevatedButton(
                    onPressed: (_saving || !widget.canEdit || widget.offline) ? null : _save,
                    child: _saving
                        ? const SizedBox(height: 18, width: 18,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Text('Save'),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
