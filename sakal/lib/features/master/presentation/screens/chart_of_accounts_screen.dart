import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';

// ── Constants ────────────────────────────────────────────────────────────────

const _natures = ['General', 'Customer', 'Supplier', 'Cash', 'Bank', 'Employee', 'Tax'];
const _partyTypes = ['Individual', 'Company', 'Partnership', 'Government'];
const _natureColors = {
  'Customer': Color(0xFFD4860B),
  'Supplier': Color(0xFF0277BD),
  'Cash':     Color(0xFF2E7D32),
  'Bank':     Color(0xFF00796B),
  'Employee': Color(0xFF6A1B9A),
  'Tax':      Color(0xFF37474F),
};

// ── Screen ───────────────────────────────────────────────────────────────────

class ChartOfAccountsScreen extends ConsumerStatefulWidget {
  const ChartOfAccountsScreen({super.key});

  @override
  ConsumerState<ChartOfAccountsScreen> createState() =>
      _ChartOfAccountsScreenState();
}

class _ChartOfAccountsScreenState
    extends ConsumerState<ChartOfAccountsScreen> {
  // Data
  List<Map<String, dynamic>> _accounts   = [];
  List<Map<String, dynamic>> _currencies = [];
  List<Map<String, dynamic>> _countries  = [];
  List<Map<String, dynamic>> _divisions  = [];
  List<Map<String, dynamic>> _cities     = [];
  bool    _loading = true;
  String? _error;

  // Tree state
  final Set<String> _expanded = {};
  List<Map<String, dynamic>> _roots    = [];
  Map<String, List<Map<String, dynamic>>> _childMap = {};

  // Panel state
  String _panelMode = 'none'; // 'none' | 'add' | 'edit'
  Map<String, dynamic>? _editNode;
  Map<String, dynamic>? _addParent;

  // Form controllers
  final _nameCtrl    = TextEditingController();
  final _codeCtrl    = TextEditingController();
  final _contactCtrl = TextEditingController();
  final _phoneCtrl   = TextEditingController();
  final _emailCtrl   = TextEditingController();
  final _addr1Ctrl   = TextEditingController();
  final _addr2Ctrl   = TextEditingController();
  final _taxIdCtrl   = TextEditingController();
  final _catCtrl     = TextEditingController();
  final _limitCtrl   = TextEditingController();
  final _daysCtrl    = TextEditingController();

  // Form state
  bool    _postingAllowed = false;
  String  _nature         = 'General';
  String? _currencyId;
  String? _partyType;
  String? _countryId;
  String? _countryCode;   // ISO code for querying cities/divisions
  String? _divisionId;
  String? _cityId;
  bool    _creditBlocked  = false;
  bool    _isActive       = true;
  bool    _partyExpanded  = false;
  bool    _isAutoCode     = false;
  String? _autoCode;
  bool    _saving         = false;
  String? _saveError;

  // Resizable panel
  double _leftWidth = 310.0;
  static const double _minLeftWidth = 200.0;
  static const double _maxLeftWidth = 520.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final c in [_nameCtrl, _codeCtrl, _contactCtrl, _phoneCtrl,
        _emailCtrl, _addr1Ctrl, _addr2Ctrl, _taxIdCtrl, _catCtrl,
        _limitCtrl, _daysCtrl]) {
      c.dispose();
    }
    super.dispose();
  }

  // ── Data loading ─────────────────────────────────────────────────────────

  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      // Accounts are screen-specific; currencies + countries come from the
      // shared session-scoped cache (fetched once, reused across all screens).
      final accountsFuture   = DioClient.instance.get('/rim_accounts', queryParameters: {
        'client_id':  'eq.${session.clientId}',
        'company_id': 'eq.${session.companyId}',
        'is_deleted': 'eq.false',
        'select':     '*',
        'order':      'account_code.asc',
        'limit':      '500',
      });
      final currenciesFuture = ref.read(currenciesProvider.future);
      final countriesFuture  = ref.read(countriesProvider.future);

      final accountsRes = await accountsFuture;
      final currencies  = await currenciesFuture;
      final countries   = await countriesFuture;

      if (mounted) {
        setState(() {
          _accounts   = List<Map<String, dynamic>>.from(accountsRes.data as List);
          _currencies = currencies;
          _countries  = countries;
          _loading    = false;
        });
        _buildTree();
        _autoExpandRoots();
      }
    } on DioException {
      if (mounted) setState(() { _loading = false; _error = 'Could not load accounts.'; });
    }
  }

  Future<void> _loadDivisions() async {
    if (_countryCode == null) return;
    final session = ref.read(sessionProvider)!;
    try {
      final res = await DioClient.instance.get('/rim_divisions', queryParameters: {
        'country_code': 'eq.$_countryCode',
        'or':           '(is_system.eq.true,and(client_id.eq.${session.clientId},company_id.eq.${session.companyId}))',
        'order':        'division_name.asc',
        'select':       'id,division_name',
      });
      if (mounted) setState(() => _divisions = List<Map<String, dynamic>>.from(res.data as List));
    } on DioException { /* silent */ }
  }

  Future<void> _loadCities() async {
    if (_countryCode == null) return;
    final session = ref.read(sessionProvider)!;
    final params = <String, dynamic>{
      'client_id':    'eq.${session.clientId}',
      'company_id':   'eq.${session.companyId}',
      'country_code': 'eq.$_countryCode',
      'select':       'id,city_name',
      'order':        'city_name.asc',
    };
    if (_divisionId != null) params['division_id'] = 'eq.$_divisionId';
    try {
      final res = await DioClient.instance.get('/rim_cities', queryParameters: params);
      if (mounted) setState(() => _cities = List<Map<String, dynamic>>.from(res.data as List));
    } on DioException { /* silent */ }
  }

  Future<void> _loadAutoCode(String parentId) async {
    final session = ref.read(sessionProvider)!;
    try {
      final res = await DioClient.instance.post('/rpc/fn_next_account_code', data: {
        'p_client_id':  session.clientId,
        'p_company_id': session.companyId,
        'p_parent_id':  parentId,
      });
      if (mounted) setState(() => _autoCode = res.data as String?);
    } on DioException { /* silent */ }
  }

  // ── Tree building ─────────────────────────────────────────────────────────

  void _buildTree() {
    _childMap = {};
    _roots    = [];
    for (final a in _accounts) {
      final pid = a['parent_id'] as String?;
      if (pid == null) { _roots.add(a); }
      else { (_childMap[pid] ??= []).add(a); }
    }
  }

  void _autoExpandRoots() {
    for (final r in _roots) { _expanded.add(r['id'] as String); }
  }

  List<({Map<String, dynamic> node, int depth})> _visibleNodes() {
    final result = <({Map<String, dynamic> node, int depth})>[];
    void traverse(List<Map<String, dynamic>> nodes, int depth) {
      for (final n in nodes) {
        result.add((node: n, depth: depth));
        final id = n['id'] as String;
        if (_expanded.contains(id)) traverse(_childMap[id] ?? [], depth + 1);
      }
    }
    traverse(_roots, 0);
    return result;
  }

  // ── Panel actions ─────────────────────────────────────────────────────────

  void _openAdd(Map<String, dynamic> parent) {
    final parentNature = parent['account_nature'] as String? ?? 'General';
    final autoNature   = parentNature == 'General' ? 'General' : parentNature;
    final needsAuto    = autoNature != 'General';

    setState(() {
      _panelMode      = 'add';
      _addParent      = parent;
      _editNode       = null;
      _postingAllowed = true;
      _nature         = autoNature;
      _isAutoCode     = needsAuto;
      _autoCode       = null;
      _partyExpanded  = needsAuto;
      _isActive       = true;
      _saveError      = null;
      _clearForm();
      _daysCtrl.text  = '30';
    });
    if (needsAuto) _loadAutoCode(parent['id'] as String);
  }

  void _openEdit(Map<String, dynamic> node) {
    final nat          = node['account_nature'] as String? ?? 'General';
    final cId          = node['country_id'] as String?;
    final country      = cId != null
        ? _countries.firstWhere((c) => c['id'] == cId, orElse: () => {})
        : <String, dynamic>{};
    final targetDivId  = node['division_id'] as String?;
    final targetCityId = node['city_id'] as String?;

    setState(() {
      _panelMode      = 'edit';
      _editNode       = node;
      _addParent      = null;
      _postingAllowed = node['posting_allowed'] as bool? ?? false;
      _nature         = nat;
      _isAutoCode     = false;
      _currencyId     = node['account_currency_id'] as String?;
      _partyType      = node['party_type'] as String?;
      _countryId      = cId;
      _countryCode    = country['country_code'] as String?;
      _divisionId     = null;   // set after divisions load
      _cityId         = null;   // set after cities load
      _creditBlocked  = node['is_credit_blocked'] as bool? ?? false;
      _isActive       = node['is_active'] as bool? ?? true;
      _partyExpanded  = false;
      _saveError      = null;
      _divisions      = [];
      _cities         = [];
      _nameCtrl.text    = node['account_name']   as String? ?? '';
      _codeCtrl.text    = node['account_code']   as String? ?? '';
      _contactCtrl.text = node['contact_person'] as String? ?? '';
      _phoneCtrl.text   = node['phone']          as String? ?? '';
      _emailCtrl.text   = node['email']          as String? ?? '';
      _addr1Ctrl.text   = node['address_line1']  as String? ?? '';
      _addr2Ctrl.text   = node['address_line2']  as String? ?? '';
      _taxIdCtrl.text   = node['tax_id']         as String? ?? '';
      _catCtrl.text     = node['party_category'] as String? ?? '';
      _limitCtrl.text   = node['credit_limit'] != null
          ? node['credit_limit'].toString() : '';
      _daysCtrl.text    = (node['credit_days'] ?? 30).toString();
    });

    if (_countryCode != null) {
      _loadDivisions().then((_) {
        if (mounted) setState(() => _divisionId = targetDivId);
      });
      _loadCities().then((_) {
        if (mounted) setState(() => _cityId = targetCityId);
      });
    }
  }

  void _clearForm() {
    _nameCtrl.clear(); _codeCtrl.clear(); _contactCtrl.clear();
    _phoneCtrl.clear(); _emailCtrl.clear(); _addr1Ctrl.clear();
    _addr2Ctrl.clear(); _taxIdCtrl.clear(); _catCtrl.clear();
    _limitCtrl.clear();
    _currencyId = null; _partyType   = null;
    _countryId  = null; _countryCode = null;
    _divisionId = null; _cityId      = null;
    _divisions  = [];   _cities      = [];
    _creditBlocked = false; _isActive = true;
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    final code = _isAutoCode ? (_autoCode ?? '') : _codeCtrl.text.trim();
    if (name.isEmpty) { setState(() => _saveError = 'Name is required.'); return; }
    if (code.isEmpty) { setState(() => _saveError = 'Code is required.'); return; }

    final session = ref.read(sessionProvider)!;
    setState(() { _saving = true; _saveError = null; });

    final isParty = _nature == 'Customer' || _nature == 'Supplier';
    final payload = <String, dynamic>{
      'client_id':           session.clientId,
      'company_id':          session.companyId,
      'account_code':        code,
      'account_name':        name,
      'posting_allowed':     _postingAllowed,
      'account_nature':      _nature,
      'account_currency_id': _currencyId,
      'is_active':           _isActive,
      'is_system_fixed':     false,
      'updated_by':          session.userId,
      if (_panelMode == 'add') ...{
        'parent_id':       _addParent?['id'],
        'accounting_std':  _addParent?['accounting_std'] ?? 'OHADA',
        'created_by':      session.userId,
      },
      if (_postingAllowed && isParty) ...{
        'party_type':        _partyType,
        'contact_person':    _contactCtrl.text.trim().nullIfEmpty,
        'phone':             _phoneCtrl.text.trim().nullIfEmpty,
        'email':             _emailCtrl.text.trim().nullIfEmpty,
        'address_line1':     _addr1Ctrl.text.trim().nullIfEmpty,
        'address_line2':     _addr2Ctrl.text.trim().nullIfEmpty,
        'country_id':        _countryId,
        'division_id':       _divisionId,
        'city_id':           _cityId,
        'tax_id':            _taxIdCtrl.text.trim().nullIfEmpty,
        'party_category':    _catCtrl.text.trim().nullIfEmpty,
        'credit_limit':      _limitCtrl.text.trim().isEmpty
            ? null : double.tryParse(_limitCtrl.text.trim()),
        'credit_days':       int.tryParse(_daysCtrl.text.trim()) ?? 30,
        'is_credit_blocked': _creditBlocked,
      },
    };

    try {
      if (_panelMode == 'add') {
        await DioClient.instance.post('/rim_accounts', data: payload);
      } else {
        await DioClient.instance.patch(
          '/rim_accounts',
          queryParameters: {'id': 'eq.${_editNode!['id']}'},
          data: payload,
        );
      }
      // The shared account picker cache (accountsProvider) is only fetched
      // once per app session — invalidate it so every other screen using it
      // (GRN, PO, Finance Voucher, Additional Charges, ...) sees this
      // ledger without needing to log out and back in.
      ref.invalidate(accountsProvider);
      await _load();
      if (mounted) setState(() { _panelMode = 'none'; });
    } on DioException catch (e) {
      if (mounted) { setState(() {
        _saveError = e.response?.data?['message'] ?? 'Save failed.';
      }); }
    } finally {
      if (mounted) { setState(() => _saving = false); }
    }
  }

  Future<void> _delete(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Account'),
        content: const Text('This account will be soft-deleted and hidden. Continue?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.negative),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final session = ref.read(sessionProvider)!;
    await DioClient.instance.patch(
      '/rim_accounts',
      queryParameters: {'id': 'eq.$id'},
      data: {'is_deleted': true, 'updated_by': session.userId},
    );
    ref.invalidate(accountsProvider);
    setState(() { _panelMode = 'none'; _editNode = null; });
    await _load();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) { return Center(
        child: Text(_error!, style: const TextStyle(color: AppColors.negative))); }

    if (Responsive.isMobile(context)) {
      // On mobile: list OR form, never side by side
      if (_panelMode == 'add' || _panelMode == 'edit') return _rightPanel();
      return _leftPanel();
    }

    return Row(children: [
      SizedBox(width: _leftWidth, child: _leftPanel()),
      // Draggable resize handle (tablet/desktop only)
      GestureDetector(
        onHorizontalDragUpdate: (d) => setState(() {
          _leftWidth = (_leftWidth + d.delta.dx)
              .clamp(_minLeftWidth, _maxLeftWidth);
        }),
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          child: SizedBox(
            width: 6,
            child: Center(child: Container(width: 1, color: AppColors.border)),
          ),
        ),
      ),
      Expanded(child: _rightPanel()),
    ]);
  }

  // ── Left panel ────────────────────────────────────────────────────────────

  Widget _leftPanel() {
    final visible = _visibleNodes();
    final mobile  = Responsive.isMobile(context);
    final offline = ref.watch(sessionProvider)?.offlineMode ?? false;
    return Column(children: [
      Container(
        color: AppColors.surface,
        padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
        child: Row(children: [
          const Expanded(child: Text('Accounts',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary))),
          IconButton(icon: const Icon(Icons.refresh, size: 18),
              tooltip: 'Refresh', onPressed: _load),
        ]),
      ),
      const Divider(height: 1, color: AppColors.border),
      Expanded(
        child: ListView.builder(
          itemCount: visible.length,
          itemBuilder: (_, i) {
            final item = visible[i];
            return _NodeRow(
              node:             item.node,
              depth:            item.depth,
              expanded:         _expanded.contains(item.node['id'] as String),
              hasChildren:      (_childMap[item.node['id'] as String]?.isNotEmpty ?? false),
              isSelected:       (_panelMode == 'edit' && _editNode?['id'] == item.node['id']),
              alwaysShowActions: mobile,
              offline: offline,
              onToggle: () => setState(() {
                final id = item.node['id'] as String;
                if (_expanded.contains(id)) { _expanded.remove(id); }
                else { _expanded.add(id); }
              }),
              onEdit: () => _openEdit(item.node),
              onAdd:  () => _openAdd(item.node),
            );
          },
        ),
      ),
      if (!offline) ...[
        const Divider(height: 1, color: AppColors.border),
        Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add Root Group', style: TextStyle(fontSize: 13)),
              onPressed: () => setState(() {
                _panelMode      = 'add';
                _addParent      = null;
                _editNode       = null;
                _postingAllowed = false;
                _nature         = 'General';
                _isAutoCode     = false;
                _partyExpanded  = false;
                _isActive       = true;
                _saveError      = null;
                _clearForm();
              }),
            ),
          ),
        ),
      ],
    ]);
  }

  // ── Right panel ───────────────────────────────────────────────────────────

  Widget _rightPanel() => switch (_panelMode) {
    'add'  => _formPanel(),
    'edit' => _formPanel(),
    _      => _emptyPanel(),
  };

  Widget _emptyPanel() => const Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.account_tree_outlined, size: 48, color: AppColors.textDisabled),
      SizedBox(height: 16),
      Text('Select a group to add an account under it,',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
      Text('or click ✏ on an existing account to edit it.',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
    ]),
  );

  Widget _formPanel() {
    final isAdd     = _panelMode == 'add';
    final isFixed   = _editNode?['is_system_fixed'] == true;
    final isGroup   = !_postingAllowed;
    final isParty   = _nature == 'Customer' || _nature == 'Supplier';
    final offline   = ref.watch(sessionProvider)?.offlineMode ?? false;
    final canDelete = !isAdd && !isFixed && !offline &&
        (_childMap[_editNode?['id'] as String? ?? '']?.isEmpty ?? true);

    final parentLabel = isAdd
        ? (_addParent != null
            ? 'Under: ${_addParent!['account_code']} — ${_addParent!['account_name']}'
            : '(None — Root Group)')
        : null;

    // Labels change for Group vs Ledger
    final codeLabel  = isGroup ? 'Group Code *'  : 'Account Code *';
    final nameLabel  = isGroup ? 'Group Name *'  : 'Account Name *';
    final codeHint   = isGroup ? 'e.g. 6100'     : 'e.g. 6150';
    final nameHint   = isGroup ? 'Enter group name' : 'Enter account name';

    return Column(children: [
      // Header
      Container(
        color: AppColors.surface,
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(isAdd ? 'Add Account' : 'Account Details',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
            if (parentLabel != null)
              Text(parentLabel,
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            if (!isAdd && isFixed)
              const Row(children: [
                Icon(Icons.lock_outline, size: 13, color: AppColors.textSecondary),
                SizedBox(width: 4),
                Text('System account — some fields are locked',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              ]),
          ])),
          if (canDelete)
            TextButton.icon(
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('Delete'),
              style: TextButton.styleFrom(foregroundColor: AppColors.negative),
              onPressed: () => _delete(_editNode!['id'] as String),
            ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() { _panelMode = 'none'; }),
          ),
        ]),
      ),
      const Divider(height: 1, color: AppColors.border),

      // Form body
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

            // ── Node Type ──────────────────────────────────────────────────
            if (isAdd) ...[
              const _Label('Node Type *'),
              const SizedBox(height: 8),
              Row(children: [
                _TypeChip(
                  label: 'Group',
                  selected: !_postingAllowed,
                  onTap: () => setState(() => _postingAllowed = false),
                ),
                const SizedBox(width: 10),
                _TypeChip(
                  label: 'Ledger',
                  selected: _postingAllowed,
                  onTap: _addParent == null
                      ? null
                      : () => setState(() => _postingAllowed = true),
                ),
              ]),
              const SizedBox(height: 4),
              Text(
                _addParent == null
                    ? 'Root accounts must be Groups — they organise top-level sections.'
                    : _postingAllowed
                        ? 'Ledger: leaf node, transactions post here. No children allowed.'
                        : 'Group: organises accounts. Cannot post transactions directly.',
                style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 20),
            ] else ...[
              const _Label('Node Type'),
              const SizedBox(height: 6),
              _ReadOnlyField(_postingAllowed ? 'Ledger' : 'Group'),
              const SizedBox(height: 16),
            ],

            // ── Code ───────────────────────────────────────────────────────
            _Label(codeLabel),
            const SizedBox(height: 6),
            if (_isAutoCode)
              _ReadOnlyField(_autoCode ?? 'Generating…', suffix: 'Auto')
            else
              TextField(
                controller: _codeCtrl,
                enabled: isAdd || !isFixed,
                decoration: InputDecoration(isDense: true, hintText: codeHint),
              ),
            const SizedBox(height: 16),

            // ── Name ───────────────────────────────────────────────────────
            _Label(nameLabel),
            const SizedBox(height: 6),
            TextField(
              controller: _nameCtrl,
              enabled: !isFixed,
              decoration: InputDecoration(isDense: true, hintText: nameHint),
            ),
            const SizedBox(height: 12),

            // ── Active (all account types) ─────────────────────────────────
            SwitchListTile.adaptive(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Active',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500,
                      color: AppColors.textPrimary)),
              subtitle: Text(
                isGroup
                    ? 'Inactive groups are hidden in the accounts tree'
                    : 'Inactive accounts cannot be selected in transactions',
                style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
              ),
              value: _isActive,
              activeThumbColor: AppColors.positive,
              onChanged: isFixed ? null : (v) => setState(() => _isActive = v),
            ),

            // ── Nature + Currency (Ledger only) ────────────────────────────
            if (_postingAllowed) ...[
              const SizedBox(height: 16),
              Builder(builder: (ctx) {
                final mobile = Responsive.isMobile(ctx);
                final natureField = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _Label('Nature *'),
                    const SizedBox(height: 6),
                    _addParent?['account_nature'] != null &&
                            _addParent!['account_nature'] != 'General'
                        ? _ReadOnlyField(_nature)
                        : DropdownButtonFormField<String>(
                            initialValue: _nature,
                            decoration: const InputDecoration(isDense: true),
                            items: _natures.map((n) => DropdownMenuItem(
                                value: n, child: Text(n))).toList(),
                            onChanged: isFixed
                                ? null
                                : (v) => setState(() => _nature = v!),
                          ),
                  ],
                );
                final currencyField = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _Label('Currency'),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      initialValue: _currencyId,
                      decoration: const InputDecoration(
                          isDense: true, hintText: 'Select…'),
                      items: _currencies.map((c) => DropdownMenuItem(
                        value: c['id'] as String,
                        child: Text('${c['currency_id']} — ${c['currency_name']}',
                            overflow: TextOverflow.ellipsis),
                      )).toList(),
                      onChanged: (v) => setState(() => _currencyId = v),
                    ),
                  ],
                );
                if (mobile) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      natureField,
                      const SizedBox(height: 14),
                      currencyField,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: natureField),
                    const SizedBox(width: 16),
                    Expanded(child: currencyField),
                  ],
                );
              }),
            ],

            // ── Party Details (Customer / Supplier Ledger only) ────────────
            if (_postingAllowed && isParty) ...[
              const SizedBox(height: 20),
              ExpansionTile(
                initiallyExpanded: _partyExpanded,
                onExpansionChanged: (v) => setState(() => _partyExpanded = v),
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: const Text('Party Details',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
                subtitle: Text(
                  _partyExpanded ? '' : _partyDetailHint(),
                  style: const TextStyle(fontSize: 11,
                      color: AppColors.textSecondary),
                ),
                children: [
                  const SizedBox(height: 12),
                  const Divider(height: 1, color: AppColors.border),
                  const SizedBox(height: 16),

                  // Party Type
                  const _Label('Party Type'),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    initialValue: _partyType,
                    decoration: const InputDecoration(
                        isDense: true, hintText: 'Select…'),
                    items: _partyTypes.map((t) => DropdownMenuItem(
                        value: t, child: Text(t))).toList(),
                    onChanged: (v) => setState(() => _partyType = v),
                  ),
                  const SizedBox(height: 14),

                  // Contact + Phone
                  Row(children: [
                    Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const _Label('Contact Person'),
                      const SizedBox(height: 6),
                      TextField(controller: _contactCtrl,
                          decoration: const InputDecoration(isDense: true)),
                    ])),
                    const SizedBox(width: 16),
                    Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const _Label('Phone'),
                      const SizedBox(height: 6),
                      TextField(controller: _phoneCtrl,
                          decoration: const InputDecoration(isDense: true)),
                    ])),
                  ]),
                  const SizedBox(height: 14),

                  // Email
                  const _Label('Email'),
                  const SizedBox(height: 6),
                  TextField(controller: _emailCtrl,
                      decoration: const InputDecoration(isDense: true)),
                  const SizedBox(height: 14),

                  // Address Line 1 & 2
                  const _Label('Address Line 1'),
                  const SizedBox(height: 6),
                  TextField(controller: _addr1Ctrl,
                      decoration: const InputDecoration(isDense: true)),
                  const SizedBox(height: 10),
                  TextField(controller: _addr2Ctrl,
                      decoration: const InputDecoration(
                          isDense: true, hintText: 'Address Line 2')),
                  const SizedBox(height: 14),

                  // Country — searchable
                  const _Label('Country'),
                  const SizedBox(height: 6),
                  _SearchablePicker(
                    value: _countryId,
                    hint: 'Select country…',
                    items: _countries,
                    labelKey: 'country_name',
                    valueKey: 'id',
                    onChanged: (item) {
                      setState(() {
                        _countryId   = item?['id'] as String?;
                        _countryCode = item?['country_code'] as String?;
                        _divisionId  = null;
                        _cityId      = null;
                        _divisions   = [];
                        _cities      = [];
                      });
                      if (_countryCode != null) {
                        _loadDivisions();
                        _loadCities();
                      }
                    },
                  ),
                  const SizedBox(height: 14),

                  // Division / State / Province
                  const _Label('Division / State / Province'),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    initialValue: _divisionId,
                    decoration: const InputDecoration(
                        isDense: true, hintText: 'Select division…'),
                    items: [
                      const DropdownMenuItem<String>(
                          value: null, child: Text('— No division —')),
                      ..._divisions.map((d) => DropdownMenuItem(
                        value: d['id'] as String,
                        child: Text(d['division_name'] as String,
                            overflow: TextOverflow.ellipsis),
                      )),
                    ],
                    onChanged: _countryCode == null
                        ? null
                        : (v) {
                            setState(() {
                              _divisionId = v;
                              _cityId     = null;
                              _cities     = [];
                            });
                            _loadCities();
                          },
                  ),
                  const SizedBox(height: 14),

                  // City
                  const _Label('City'),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    initialValue: _cityId,
                    decoration: const InputDecoration(
                        isDense: true, hintText: 'Select…'),
                    items: _cities.map((c) => DropdownMenuItem(
                      value: c['id'] as String,
                      child: Text(c['city_name'] as String,
                          overflow: TextOverflow.ellipsis),
                    )).toList(),
                    onChanged: (v) => setState(() => _cityId = v),
                  ),
                  const SizedBox(height: 14),

                  // Tax ID
                  const _Label('Tax ID (TVA / TIN / GSTIN)'),
                  const SizedBox(height: 6),
                  TextField(controller: _taxIdCtrl,
                      decoration: const InputDecoration(isDense: true)),
                  const SizedBox(height: 14),

                  // Category + Credit Days + Credit Limit
                  Builder(builder: (ctx) {
                    final mobile = Responsive.isMobile(ctx);
                    final catField = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _Label('Category'),
                        const SizedBox(height: 6),
                        TextField(controller: _catCtrl,
                            decoration: const InputDecoration(
                                isDense: true, hintText: 'e.g. Wholesale')),
                      ],
                    );
                    final daysField = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _Label('Credit Days'),
                        const SizedBox(height: 6),
                        TextField(controller: _daysCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(isDense: true)),
                      ],
                    );
                    final limitField = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _Label('Credit Limit'),
                        const SizedBox(height: 6),
                        TextField(controller: _limitCtrl,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(
                                isDense: true, hintText: '0.00')),
                      ],
                    );
                    if (mobile) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          catField,
                          const SizedBox(height: 14),
                          Row(children: [
                            Expanded(child: daysField),
                            const SizedBox(width: 12),
                            Expanded(child: limitField),
                          ]),
                        ],
                      );
                    }
                    return Row(children: [
                      Expanded(child: catField),
                      const SizedBox(width: 12),
                      SizedBox(width: 90, child: daysField),
                      const SizedBox(width: 12),
                      Expanded(child: limitField),
                    ]);
                  }),
                  const SizedBox(height: 14),

                  // Credit Blocked
                  Row(children: [
                    Checkbox(
                      value: _creditBlocked,
                      onChanged: (v) => setState(() => _creditBlocked = v!),
                    ),
                    const Text('Credit Blocked',
                        style: TextStyle(fontSize: 13,
                            color: AppColors.textPrimary)),
                  ]),
                ],
              ),
            ],

            if (_saveError != null) ...[
              const SizedBox(height: 16),
              Text(_saveError!,
                  style: const TextStyle(
                      color: AppColors.negative, fontSize: 13)),
            ],

            const SizedBox(height: 24),
            if (!isFixed)
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                OutlinedButton(
                  onPressed: () => setState(() => _panelMode = 'none'),
                  child: const Text('Cancel'),
                ),
                if (!offline) ...[
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(width: 18, height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Text(isAdd ? 'Save Account' : 'Save Changes'),
                  ),
                ],
              ]),
          ]),
        ),
      ),
    ]);
  }

  String _partyDetailHint() {
    final parts = <String>[];
    if (_partyType != null) parts.add(_partyType!);
    final contact = _contactCtrl.text.trim();
    if (contact.isNotEmpty) parts.add(contact);
    final phone = _phoneCtrl.text.trim();
    if (phone.isNotEmpty) parts.add(phone);
    return parts.isEmpty ? '(not filled yet)' : parts.join(' · ');
  }
}

// ── Node Row Widget ───────────────────────────────────────────────────────────

class _NodeRow extends StatefulWidget {
  final Map<String, dynamic> node;
  final int          depth;
  final bool         expanded;
  final bool         hasChildren;
  final bool         isSelected;
  final bool         alwaysShowActions;
  final bool         offline;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onAdd;

  const _NodeRow({
    required this.node,
    required this.depth,
    required this.expanded,
    required this.hasChildren,
    required this.isSelected,
    required this.alwaysShowActions,
    required this.offline,
    required this.onToggle,
    required this.onEdit,
    required this.onAdd,
  });

  @override
  State<_NodeRow> createState() => _NodeRowState();
}

class _NodeRowState extends State<_NodeRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final node        = widget.node;
    final isFixed     = node['is_system_fixed'] == true;
    final isLeaf      = node['posting_allowed']  == true;
    final nature      = node['account_nature']   as String? ?? 'General';
    final natureColor = _natureColors[nature];

    final showActions = _hovered || widget.alwaysShowActions;
    final rowHeight   = widget.alwaysShowActions ? 48.0 : 36.0;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit:  (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: widget.onEdit,
        child: Container(
          height: rowHeight,
          color: widget.isSelected
              ? const Color(0xFFEAF0FB)
              : _hovered ? AppColors.surfaceVariant : null,
          padding: EdgeInsets.only(left: 8.0 + widget.depth * 16.0, right: 8),
          child: Row(children: [
            SizedBox(
              width: 20,
              child: !isLeaf
                  ? GestureDetector(
                      onTap: widget.onToggle,
                      child: Icon(
                        widget.expanded
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_right,
                        size: 18,
                        color: AppColors.textSecondary,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 4),
            Icon(
              isLeaf ? Icons.description_outlined : Icons.folder_outlined,
              size: 15,
              color: isFixed ? AppColors.textDisabled : AppColors.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              node['account_code'] as String? ?? '',
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: isFixed ? AppColors.textDisabled : AppColors.textSecondary,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                node['account_name'] as String? ?? '',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: widget.isSelected
                      ? FontWeight.w600 : FontWeight.normal,
                  color: isFixed
                      ? AppColors.textDisabled : AppColors.textPrimary,
                ),
              ),
            ),
            if (natureColor != null && !_hovered && !widget.isSelected)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: natureColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(nature,
                    style: TextStyle(fontSize: 10, color: natureColor,
                        fontWeight: FontWeight.w600)),
              ),
            if (isFixed)
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(Icons.lock_outline, size: 13,
                    color: AppColors.textDisabled),
              ),
            if (showActions) ...[
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 15),
                tooltip: 'Edit',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: widget.onEdit,
              ),
              if (!isLeaf && !widget.offline)
                IconButton(
                  icon: const Icon(Icons.add, size: 15),
                  tooltip: 'Add account under this group',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  onPressed: widget.onAdd,
                ),
            ],
          ]),
        ),
      ),
    );
  }
}

// ── Searchable Picker ─────────────────────────────────────────────────────────

class _SearchablePicker extends StatelessWidget {
  final String?                    value;
  final String                     hint;
  final List<Map<String, dynamic>> items;
  final String                     labelKey;
  final String                     valueKey;
  final ValueChanged<Map<String, dynamic>?> onChanged;

  const _SearchablePicker({
    required this.value,
    required this.hint,
    required this.items,
    required this.labelKey,
    required this.valueKey,
    required this.onChanged,
  });

  String? get _displayLabel {
    if (value == null) return null;
    final item = items.firstWhere(
      (i) => i[valueKey] == value,
      orElse: () => {},
    );
    return item[labelKey] as String?;
  }

  @override
  Widget build(BuildContext context) {
    final label = _displayLabel;
    return InkWell(
      onTap: () async {
        final result = await showDialog<Map<String, dynamic>>(
          context: context,
          builder: (ctx) => _SearchDialog(
              title: hint, items: items, labelKey: labelKey),
        );
        if (result != null) onChanged(result);
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          Expanded(
            child: Text(
              label ?? hint,
              style: TextStyle(
                fontSize: 13,
                color: label != null
                    ? AppColors.textPrimary
                    : AppColors.textDisabled,
              ),
            ),
          ),
          if (value != null)
            GestureDetector(
              onTap: () => onChanged(null),
              child: const Icon(Icons.close, size: 16,
                  color: AppColors.textSecondary),
            )
          else
            const Icon(Icons.arrow_drop_down, size: 20,
                color: AppColors.textSecondary),
        ]),
      ),
    );
  }
}

class _SearchDialog extends StatefulWidget {
  final String                     title;
  final List<Map<String, dynamic>> items;
  final String                     labelKey;

  const _SearchDialog({
    required this.title,
    required this.items,
    required this.labelKey,
  });

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  String _query = '';
  late List<Map<String, dynamic>> _filtered;

  @override
  void initState() {
    super.initState();
    _filtered = widget.items;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Search…',
              prefixIcon: Icon(Icons.search, size: 18),
              isDense: true,
            ),
            onChanged: (v) => setState(() {
              _query = v;
              _filtered = widget.items
                  .where((i) => (i[widget.labelKey] as String)
                      .toLowerCase()
                      .contains(_query.toLowerCase()))
                  .toList();
            }),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _filtered.length,
              itemBuilder: (_, i) => ListTile(
                dense: true,
                title: Text(_filtered[i][widget.labelKey] as String,
                    style: const TextStyle(fontSize: 13)),
                onTap: () => Navigator.of(context, rootNavigator: true)
                    .pop(_filtered[i]),
              ),
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

// ── Small helpers ─────────────────────────────────────────────────────────────

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
          color: AppColors.textPrimary));
}

class _TypeChip extends StatelessWidget {
  final String       label;
  final bool         selected;
  final VoidCallback? onTap;
  const _TypeChip({required this.label, required this.selected, this.onTap});

  bool get _disabled => onTap == null;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(6),
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(
            color: selected ? AppColors.primary
                : _disabled ? AppColors.border.withValues(alpha: 0.4)
                : AppColors.border,
            width: selected ? 2 : 1),
        borderRadius: BorderRadius.circular(6),
        color: selected ? const Color(0xFFEAF0FB)
            : _disabled ? AppColors.surfaceVariant
            : AppColors.surface,
      ),
      child: Text(label, style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: selected ? AppColors.primary
              : _disabled ? AppColors.textDisabled
              : AppColors.textSecondary)),
    ),
  );
}

class _ReadOnlyField extends StatelessWidget {
  final String  value;
  final String? suffix;
  const _ReadOnlyField(this.value, {this.suffix});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: AppColors.surfaceVariant,
      border: Border.all(color: AppColors.border),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(children: [
      Expanded(child: Text(value,
          style: const TextStyle(fontSize: 13,
              color: AppColors.textSecondary))),
      if (suffix != null)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.border,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(suffix!,
              style: const TextStyle(fontSize: 10,
                  color: AppColors.textSecondary)),
        ),
    ]),
  );
}

extension _NullIfEmpty on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
