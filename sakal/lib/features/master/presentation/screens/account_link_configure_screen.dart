import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/database/datasources/generic_lookup_local_ds.dart';
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

/// Configure the granularity (Company / Category / Location / Item) and
/// the account assignments for a single account-link type.
/// See backend/migrations/032_account_link_setup.sql.
class AccountLinkConfigureScreen extends ConsumerStatefulWidget {
  final String linkTypeId;
  final String linkKey;
  final String linkName;
  const AccountLinkConfigureScreen({
    super.key,
    required this.linkTypeId,
    required this.linkKey,
    required this.linkName,
  });

  @override
  ConsumerState<AccountLinkConfigureScreen> createState() => _AccountLinkConfigureScreenState();
}

class _AccountLinkConfigureScreenState extends ConsumerState<AccountLinkConfigureScreen>
    with ScreenPermissionMixin<AccountLinkConfigureScreen> {
  @override String get screenName => RouteNames.accountLinkSetup;

  String? _level;
  String? _setupId;
  List<Map<String, dynamic>> _defaults = [];   // rows: id, link_key_id, account_id
  List<ItemCategoryModel>    _categories = [];
  List<Map<String, dynamic>> _products = [];
  bool _productsLoaded = false;

  bool    _loading = true;
  bool    _busy    = false;
  String? _error;

  // Add-row controllers (Category / Item levels)
  String? _pendingKeyId;
  String? _pendingAccountId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      List<Map<String, dynamic>> setupRows;
      List<Map<String, dynamic>> defaultRows;

      if (session.offlineMode && !kIsWeb) {
        // Shared cache with the list screen — holds ALL link types for this
        // company, so filter down to this one client-side after reading.
        final local = GenericLookupLocalDs(ref.read(appDatabaseProvider));
        final allSetup = await local.getLookups(
            cacheKey: 'ACCOUNT_LINK_SETUP', clientId: session.clientId, companyId: session.companyId);
        final allDefaults = await local.getLookups(
            cacheKey: 'ACCOUNT_LINK_DEFAULTS', clientId: session.clientId, companyId: session.companyId);
        setupRows   = allSetup.where((r) => r['link_type_id'] == widget.linkTypeId).toList();
        defaultRows = allDefaults.where((r) => r['link_type_id'] == widget.linkTypeId).toList();
      } else {
        final dioResults = await Future.wait([
          DioClient.instance.get('/rim_account_link_setup', queryParameters: {
            'client_id':    'eq.${session.clientId}',
            'company_id':   'eq.${session.companyId}',
            'link_type_id': 'eq.${widget.linkTypeId}',
            'select':       'id,link_type_id,link_type',
            'limit':        '1',
          }),
          DioClient.instance.get('/rim_account_link_defaults', queryParameters: {
            'client_id':    'eq.${session.clientId}',
            'company_id':   'eq.${session.companyId}',
            'link_type_id': 'eq.${widget.linkTypeId}',
            'is_deleted':   'eq.false',
            'select':       'id,link_type_id,link_key_id,account_id,'
                            'account:rim_accounts!account_id(account_code,account_name)',
          }),
        ]);
        setupRows   = List<Map<String, dynamic>>.from(dioResults[0].data as List);
        defaultRows = List<Map<String, dynamic>>.from(dioResults[1].data as List);

        if (!kIsWeb) {
          final local = GenericLookupLocalDs(ref.read(appDatabaseProvider));
          unawaited(local.upsertLookups(
            cacheKey: 'ACCOUNT_LINK_SETUP', rows: setupRows, idOf: (r) => r['id'] as String,
            clientId: session.clientId, companyId: session.companyId,
          ));
          unawaited(local.upsertLookups(
            cacheKey: 'ACCOUNT_LINK_DEFAULTS', rows: defaultRows, idOf: (r) => r['id'] as String,
            clientId: session.clientId, companyId: session.companyId,
          ));
        }
      }

      final categories = await ref.read(itemCategoriesRepositoryProvider).getCategories(
          clientId: session.clientId, companyId: session.companyId);
      if (!mounted) return;
      setState(() {
        _setupId  = setupRows.isNotEmpty ? setupRows.first['id'] as String : null;
        _level    = setupRows.isNotEmpty ? setupRows.first['link_type'] as String : null;
        _defaults = defaultRows;
        _categories = categories;
        _loading    = false;
      });
      if (_level == 'ITEM') await _loadProducts();
    } on DioException {
      if (mounted) setState(() { _loading = false; _error = 'Could not load configuration.'; });
    }
  }

  Future<void> _loadProducts() async {
    if (_productsLoaded) return;
    final session = ref.read(sessionProvider)!;
    final res = await DioClient.instance.get('/rim_products', queryParameters: {
      'client_id':  'eq.${session.clientId}',
      'company_id': 'eq.${session.companyId}',
      'is_active':  'eq.true',
      'is_deleted': 'eq.false',
      'select':     'id,product_code,product_name',
      'order':      'product_name.asc',
      'limit':      '1000',
    });
    if (!mounted) return;
    setState(() {
      _products = List<Map<String, dynamic>>.from(res.data as List);
      _productsLoaded = true;
    });
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppColors.negative));
  }

  Future<void> _clearCache([String? linkKeyId]) async {
    final session = ref.read(sessionProvider)!;
    try {
      await DioClient.instance.post('/rpc/fn_clear_account_link_cache', data: {
        'p_client_id':   session.clientId,
        'p_company_id':  session.companyId,
        'p_link_key':    widget.linkKey,
        'p_link_key_id': linkKeyId,
      });
    } on DioException { /* best-effort — stale cache self-heals on next default change */ }
  }

  Future<void> _changeLevel(String newLevel) async {
    if (newLevel == _level) return;
    if (_defaults.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Switch Level?'),
          content: Text('Switching to a different level will remove the ${_defaults.length} '
              'existing assignment(s) for "${widget.linkName}". Continue?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context, rootNavigator: true).pop(false),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
                child: const Text('Switch', style: TextStyle(color: AppColors.negative))),
          ],
        ),
      );
      if (ok != true) return;
    }

    setState(() => _busy = true);
    final session = ref.read(sessionProvider)!;
    try {
      // Remove existing defaults — they don't apply under the new level.
      for (final d in _defaults) {
        await DioClient.instance.patch('/rim_account_link_defaults',
            queryParameters: {'id': 'eq.${d['id']}'},
            data: {'is_deleted': true},
            options: Options(headers: {'Prefer': 'return=minimal'}));
      }
      await _clearCache(); // whole link type for this company

      if (_setupId != null) {
        await DioClient.instance.patch('/rim_account_link_setup',
            queryParameters: {'id': 'eq.$_setupId'},
            data: {'link_type': newLevel, 'updated_at': DateTime.now().toUtc().toIso8601String(),
                   'updated_by': session.userId},
            options: Options(headers: {'Prefer': 'return=minimal'}));
      } else {
        await DioClient.instance.post('/rim_account_link_setup', data: {
          'client_id': session.clientId, 'company_id': session.companyId,
          'link_type_id': widget.linkTypeId, 'link_type': newLevel,
          'created_by': session.userId,
        }, options: Options(headers: {'Prefer': 'return=minimal'}));
      }

      if (newLevel == 'ITEM') await _loadProducts();
      if (mounted) {
        setState(() { _level = newLevel; _defaults = []; _busy = false; _pendingKeyId = null; _pendingAccountId = null; });
      }
      _load();
    } on DioException {
      if (mounted) { setState(() => _busy = false); _showError('Could not switch level.'); }
    }
  }

  Future<void> _upsertDefault({String? linkKeyId, required String accountId, String? existingId}) async {
    final session = ref.read(sessionProvider)!;
    setState(() => _busy = true);
    try {
      if (existingId != null) {
        await DioClient.instance.patch('/rim_account_link_defaults',
            queryParameters: {'id': 'eq.$existingId'},
            data: {'account_id': accountId, 'updated_at': DateTime.now().toUtc().toIso8601String(),
                   'updated_by': session.userId},
            options: Options(headers: {'Prefer': 'return=minimal'}));
      } else {
        await DioClient.instance.post('/rim_account_link_defaults', data: {
          'client_id': session.clientId, 'company_id': session.companyId,
          'link_type_id': widget.linkTypeId, 'link_key_id': linkKeyId, 'account_id': accountId,
          'created_by': session.userId,
        }, options: Options(headers: {'Prefer': 'return=minimal'}));
      }
      await _clearCache(linkKeyId);
      if (mounted) { setState(() { _busy = false; _pendingKeyId = null; _pendingAccountId = null; }); }
      _load();
    } on DioException catch (e) {
      if (mounted) { setState(() => _busy = false); _showError(e.response?.data?['message'] as String? ?? 'Save failed.'); }
    }
  }

  Future<void> _removeDefault(Map<String, dynamic> row) async {
    setState(() => _busy = true);
    try {
      await DioClient.instance.patch('/rim_account_link_defaults',
          queryParameters: {'id': 'eq.${row['id']}'},
          data: {'is_deleted': true},
          options: Options(headers: {'Prefer': 'return=minimal'}));
      await _clearCache(row['link_key_id'] as String?);
      if (mounted) setState(() => _busy = false);
      _load();
    } on DioException {
      if (mounted) { setState(() => _busy = false); _showError('Could not remove assignment.'); }
    }
  }

  @override
  Widget build(BuildContext context) {
    final offline = ref.watch(sessionProvider)?.offlineMode ?? false;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).maybePop()),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.linkName,
                          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                      const SizedBox(height: 4),
                      const Text('Choose how this account is determined, then assign it.',
                          style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                    ],
                  ),
                ),
              ]),
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
                Card(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Level', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                        const SizedBox(height: 8),
                        SegmentedButton<String>(
                          showSelectedIcon: false,
                          emptySelectionAllowed: true,
                          segments: const [
                            ButtonSegment(value: 'COMPANY',  label: Text('Company-wide')),
                            ButtonSegment(value: 'CATEGORY', label: Text('Category-wise')),
                            ButtonSegment(value: 'LOCATION', label: Text('Location-wise')),
                            ButtonSegment(value: 'ITEM',     label: Text('Item-wise')),
                          ],
                          selected: _level != null ? {_level!} : const {},
                          onSelectionChanged: (canEdit && !offline && !_busy)
                              ? (s) { if (s.isNotEmpty) _changeLevel(s.first); }
                              : null,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                if (_level == null)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('Pick a level above to start assigning accounts.',
                        style: TextStyle(color: AppColors.textSecondary)),
                  )
                else
                  _buildLevelBody(offline),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLevelBody(bool offline) {
    final accountsAsync = ref.watch(accountsProvider);
    return accountsAsync.when(
      loading: () => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
      error: (e, _) => Text('Could not load accounts: $e', style: const TextStyle(fontSize: 12, color: AppColors.negative)),
      data: (accounts) {
        switch (_level) {
          case 'COMPANY':
            return _buildCompanyLevel(accounts, offline);
          case 'LOCATION':
            return _buildLocationLevel(accounts, offline);
          case 'CATEGORY':
            return _buildCategoryLevel(accounts, offline);
          case 'ITEM':
            return _buildKeyedLevel(accounts, offline);
          default:
            return const SizedBox.shrink();
        }
      },
    );
  }

  String _displayAccount(Map<String, dynamic> a) => '[${a['account_code']}] ${a['account_name']}';

  Widget _accountAutocomplete({
    required List<Map<String, dynamic>> accounts,
    required String? currentAccountId,
    required bool enabled,
    required void Function(String accountId) onPicked,
  }) {
    final matches  = accounts.where((a) => a['id'] == currentAccountId).toList();
    final selected = matches.isNotEmpty ? matches.first : null;
    return Autocomplete<Map<String, dynamic>>(
      key: ValueKey(currentAccountId ?? 'none'),
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
        enabled: enabled,
        decoration: const InputDecoration(labelText: 'Account', prefixIcon: Icon(Icons.account_balance_outlined)),
        style: const TextStyle(fontSize: 13),
      ),
      onSelected: (a) => onPicked(a['id'] as String),
      optionsViewBuilder: (context, onSel, options) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(4),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240, maxWidth: 460),
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
  }

  Widget _buildCompanyLevel(List<Map<String, dynamic>> accounts, bool offline) {
    final existing = _defaults.isNotEmpty ? _defaults.first : null;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: _accountAutocomplete(
            accounts: accounts,
            currentAccountId: existing?['account_id'] as String?,
            enabled: canEdit && !offline && !_busy,
            onPicked: (id) => _upsertDefault(accountId: id, existingId: existing?['id'] as String?),
          ),
        ),
      ),
    );
  }

  Widget _buildLocationLevel(List<Map<String, dynamic>> accounts, bool offline) {
    final isMobile = Responsive.isMobile(context);
    final locationsAsync = ref.watch(locationsProvider);
    return locationsAsync.when(
      loading: () => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
      error: (e, _) => Text('Could not load locations: $e', style: const TextStyle(fontSize: 12, color: AppColors.negative)),
      data: (locations) => Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Column(
          children: locations.map((loc) {
            final existing = _defaults.where((d) => d['link_key_id'] == loc['id']).toList();
            final row = existing.isNotEmpty ? existing.first : null;
            final picker = _accountAutocomplete(
              accounts: accounts,
              currentAccountId: row?['account_id'] as String?,
              enabled: canEdit && !offline && !_busy,
              onPicked: (id) => _upsertDefault(
                  linkKeyId: loc['id'] as String, accountId: id, existingId: row?['id'] as String?),
            );
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: isMobile
                  ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(loc['location_name'] ?? '', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      picker,
                    ])
                  : Row(children: [
                      Expanded(flex: 2, child: Text(loc['location_name'] ?? '', style: const TextStyle(fontSize: 13))),
                      Expanded(flex: 3, child: picker),
                    ]),
            );
          }).toList(),
        ),
      ),
    );
  }

  // Category-wise is restricted to Level 1 (main categories) for now — every
  // Level 1 category is shown directly, same UX as Location-wise. Deeper
  // levels can be enabled later without any schema change (link_key_id
  // already accepts any category id); this is purely a UI restriction.
  Widget _buildCategoryLevel(List<Map<String, dynamic>> accounts, bool offline) {
    final isMobile = Responsive.isMobile(context);
    final level1 = _categories.where((c) => c.id != null && c.levelNo == 1).toList()
      ..sort((a, b) => a.categoryName.compareTo(b.categoryName));
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: level1.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(20),
              child: Text('No main categories set up yet.', style: TextStyle(color: AppColors.textSecondary)),
            )
          : Column(
              children: level1.map((cat) {
                final existing = _defaults.where((d) => d['link_key_id'] == cat.id).toList();
                final row = existing.isNotEmpty ? existing.first : null;
                final picker = _accountAutocomplete(
                  accounts: accounts,
                  currentAccountId: row?['account_id'] as String?,
                  enabled: canEdit && !offline && !_busy,
                  onPicked: (id) => _upsertDefault(
                      linkKeyId: cat.id!, accountId: id, existingId: row?['id'] as String?),
                );
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: isMobile
                      ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(cat.categoryName, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 6),
                          picker,
                        ])
                      : Row(children: [
                          Expanded(flex: 2, child: Text(cat.categoryName, style: const TextStyle(fontSize: 13))),
                          Expanded(flex: 3, child: picker),
                        ]),
                );
              }).toList(),
            ),
    );
  }

  Widget _buildKeyedLevel(List<Map<String, dynamic>> accounts, bool offline) {
    final isMobile = Responsive.isMobile(context);
    final keyOptions = _products;

    final productPicker = KeyedSubtree(
      key: ValueKey('key-picker-${_defaults.length}'),
      child: _productAutocomplete(offline),
    );
    final accountPicker = _accountAutocomplete(
      accounts: accounts,
      currentAccountId: _pendingAccountId,
      enabled: canEdit && !offline && !_busy,
      onPicked: (id) => setState(() => _pendingAccountId = id),
    );
    final addButton = ElevatedButton(
      onPressed: (canEdit && !offline && !_busy && _pendingKeyId != null && _pendingAccountId != null)
          ? () => _upsertDefault(linkKeyId: _pendingKeyId, accountId: _pendingAccountId!)
          : null,
      child: const Text('Add'),
    );

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isMobile)
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                productPicker,
                const SizedBox(height: 12),
                accountPicker,
                const SizedBox(height: 12),
                SizedBox(width: double.infinity, child: addButton),
              ])
            else
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 3, child: productPicker),
                const SizedBox(width: 12),
                Expanded(flex: 3, child: accountPicker),
                const SizedBox(width: 12),
                addButton,
              ]),
            if (keyOptions.isEmpty && !_productsLoaded)
              const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
            const SizedBox(height: 20),
            if (_defaults.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('No assignments yet.', style: TextStyle(color: AppColors.textSecondary)),
              )
            else
              ..._defaults.map((d) {
                final acc = d['account'] as Map<String, dynamic>?;
                final label = (_products.where((p) => p['id'] == d['link_key_id']).map((p) => '${p['product_code']} — ${p['product_name']}').firstOrNull ?? d['link_key_id']) as String;
                final accountText = acc != null ? '[${acc['account_code']}] ${acc['account_name']}' : '—';
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: isMobile
                      ? Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                              Text(accountText, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                            ]),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.negative),
                            onPressed: (canEdit && !offline && !_busy) ? () => _removeDefault(d) : null,
                          ),
                        ])
                      : Row(children: [
                          Expanded(flex: 3, child: Text(label, style: const TextStyle(fontSize: 13))),
                          Expanded(flex: 3, child: Text(accountText, style: const TextStyle(fontSize: 13, color: AppColors.textSecondary))),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.negative),
                            onPressed: (canEdit && !offline && !_busy) ? () => _removeDefault(d) : null,
                          ),
                        ]),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _productAutocomplete(bool offline) => Autocomplete<Map<String, dynamic>>(
    displayStringForOption: (p) => '${p['product_code']} — ${p['product_name']}',
    optionsBuilder: (v) {
      final q = v.text.toLowerCase().trim();
      if (q.isEmpty) return _products.take(50);
      return _products.where((p) =>
          (p['product_code'] as String? ?? '').toLowerCase().contains(q) ||
          (p['product_name'] as String? ?? '').toLowerCase().contains(q)).take(50);
    },
    onSelected: (p) => setState(() => _pendingKeyId = p['id'] as String),
    fieldViewBuilder: (context, textCtrl, focusNode, onFieldSubmitted) => TextFormField(
      controller: textCtrl,
      focusNode: focusNode,
      enabled: canEdit && !offline && !_busy,
      decoration: const InputDecoration(labelText: 'Item', prefixIcon: Icon(Icons.inventory_2_outlined)),
      style: const TextStyle(fontSize: 13),
    ),
    optionsViewBuilder: (context, onSel, options) => Align(
      alignment: Alignment.topLeft,
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(4),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240, maxWidth: 400),
          child: ListView.builder(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            itemCount: options.length,
            itemBuilder: (context, idx) {
              final p = options.elementAt(idx);
              return InkWell(
                onTap: () => onSel(p),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Text('${p['product_code']} — ${p['product_name']}', style: const TextStyle(fontSize: 13)),
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
}
