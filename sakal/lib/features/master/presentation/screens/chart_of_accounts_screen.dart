import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';

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
  List<Map<String, dynamic>> _cities     = [];
  bool    _loading = true;
  String? _error;

  // Tree state
  final Set<String> _expanded = {};
  List<Map<String, dynamic>> _roots    = [];
  Map<String, List<Map<String, dynamic>>> _childMap = {};

  // Panel state: 'none' | 'add' | 'edit'
  String _panelMode = 'none';
  Map<String, dynamic>? _editNode;    // node being edited
  Map<String, dynamic>? _addParent;   // parent for add mode

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
  String? _cityId;
  bool    _creditBlocked  = false;
  bool    _partyExpanded  = false;
  bool    _isAutoCode     = false;
  String? _autoCode;
  bool    _saving         = false;
  String? _saveError;

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
      final results = await Future.wait([
        DioClient.instance.get('/rim_accounts', queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false',
          'select':     '*',
          'order':      'account_code.asc',
        }),
        DioClient.instance.get('/rim_currencies', queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'is_active':  'eq.true',
          'select':     'id,currency_id,currency_name',
          'order':      'currency_id.asc',
        }),
        DioClient.instance.get('/rim_countries', queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'select':     'id,country_name',
          'order':      'country_name.asc',
        }),
      ]);
      if (mounted) {
        setState(() {
          _accounts   = List<Map<String, dynamic>>.from(results[0].data as List);
          _currencies = List<Map<String, dynamic>>.from(results[1].data as List);
          _countries  = List<Map<String, dynamic>>.from(results[2].data as List);
          _loading    = false;
        });
        _buildTree();
        _autoExpandRoots();
      }
    } on DioException {
      if (mounted) setState(() { _loading = false; _error = 'Could not load accounts.'; });
    }
  }

  Future<void> _loadCities(String countryId) async {
    final session = ref.read(sessionProvider)!;
    try {
      final res = await DioClient.instance.get('/rim_cities', queryParameters: {
        'client_id':    'eq.${session.clientId}',
        'company_id':   'eq.${session.companyId}',
        'country_id':   'eq.$countryId',
        'select':       'id,city_name',
        'order':        'city_name.asc',
      });
      if (mounted) setState(() => _cities = List<Map<String, dynamic>>.from(res.data as List));
    } on DioException { /* silent */ }
  }

  Future<void> _loadAutoCode(String parentId) async {
    final session = ref.read(sessionProvider)!;
    try {
      final res = await DioClient.instance.post(
        '/rpc/fn_next_account_code',
        data: {
          'p_client_id':  session.clientId,
          'p_company_id': session.companyId,
          'p_parent_id':  parentId,
        },
      );
      if (mounted) setState(() => _autoCode = res.data as String?);
    } on DioException { /* silent */ }
  }

  // ── Tree building ─────────────────────────────────────────────────────────

  void _buildTree() {
    _childMap = {};
    _roots    = [];
    for (final a in _accounts) {
      final pid = a['parent_id'] as String?;
      if (pid == null) {
        _roots.add(a);
      } else {
        (_childMap[pid] ??= []).add(a);
      }
    }
  }

  void _autoExpandRoots() {
    for (final r in _roots) {
      _expanded.add(r['id'] as String);
    }
  }

  List<({Map<String, dynamic> node, int depth})> _visibleNodes() {
    final result = <({Map<String, dynamic> node, int depth})>[];
    void traverse(List<Map<String, dynamic>> nodes, int depth) {
      for (final n in nodes) {
        result.add((node: n, depth: depth));
        final id = n['id'] as String;
        if (_expanded.contains(id)) {
          traverse(_childMap[id] ?? [], depth + 1);
        }
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
      _partyExpanded  = needsAuto; // expand party section for Customer/Supplier
      _saveError      = null;
      _clearForm();
      _daysCtrl.text  = '30';
    });

    if (needsAuto) _loadAutoCode(parent['id'] as String);
  }

  void _openEdit(Map<String, dynamic> node) {
    final nat = node['account_nature'] as String? ?? 'General';
    setState(() {
      _panelMode      = 'edit';
      _editNode       = node;
      _addParent      = null;
      _postingAllowed = node['posting_allowed'] as bool? ?? false;
      _nature         = nat;
      _isAutoCode     = false;
      _currencyId     = node['account_currency_id'] as String?;
      _partyType      = node['party_type'] as String?;
      _countryId      = node['country_id'] as String?;
      _cityId         = node['city_id'] as String?;
      _creditBlocked  = node['is_credit_blocked'] as bool? ?? false;
      _partyExpanded  = false;
      _saveError      = null;
      _nameCtrl.text    = node['account_name']   as String? ?? '';
      _codeCtrl.text    = node['account_code']   as String? ?? '';
      _contactCtrl.text = node['contact_person'] as String? ?? '';
      _phoneCtrl.text   = node['phone']          as String? ?? '';
      _emailCtrl.text   = node['email']          as String? ?? '';
      _addr1Ctrl.text   = node['address_line1']  as String? ?? '';
      _addr2Ctrl.text   = node['address_line2']  as String? ?? '';
      _taxIdCtrl.text   = node['tax_id']         as String? ?? '';
      _catCtrl.text     = node['party_category'] as String? ?? '';
      _limitCtrl.text   = (node['credit_limit'] != null)
          ? node['credit_limit'].toString() : '';
      _daysCtrl.text    = (node['credit_days'] ?? 30).toString();
    });
    if (_countryId != null) _loadCities(_countryId!);
  }

  void _clearForm() {
    _nameCtrl.clear(); _codeCtrl.clear(); _contactCtrl.clear();
    _phoneCtrl.clear(); _emailCtrl.clear(); _addr1Ctrl.clear();
    _addr2Ctrl.clear(); _taxIdCtrl.clear(); _catCtrl.clear();
    _limitCtrl.clear(); _currencyId = null; _partyType = null;
    _countryId = null; _cityId = null; _creditBlocked = false;
    _cities = [];
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    final code = _isAutoCode ? (_autoCode ?? '') : _codeCtrl.text.trim();
    if (name.isEmpty) { setState(() => _saveError = 'Account name is required.'); return; }
    if (code.isEmpty) { setState(() => _saveError = 'Account code is required.'); return; }

    final session = ref.read(sessionProvider)!;
    setState(() { _saving = true; _saveError = null; });

    final isParty = _nature == 'Customer' || _nature == 'Supplier';
    final payload = <String, dynamic>{
      'client_id':          session.clientId,
      'company_id':         session.companyId,
      'account_code':       code,
      'account_name':       name,
      'posting_allowed':    _postingAllowed,
      'account_nature':     _nature,
      'account_currency_id': _currencyId,
      'is_system_fixed':    false,
      'updated_by':         session.userId,
      if (_panelMode == 'add') ...{
        'parent_id':        _addParent?['id'],
        'accounting_std':   _addParent?['accounting_std'] ?? 'OHADA',
        'created_by':       session.userId,
      },
      if (isParty) ...{
        'party_type':       _partyType,
        'contact_person':   _contactCtrl.text.trim().nullIfEmpty,
        'phone':            _phoneCtrl.text.trim().nullIfEmpty,
        'email':            _emailCtrl.text.trim().nullIfEmpty,
        'address_line1':    _addr1Ctrl.text.trim().nullIfEmpty,
        'address_line2':    _addr2Ctrl.text.trim().nullIfEmpty,
        'country_id':       _countryId,
        'city_id':          _cityId,
        'tax_id':           _taxIdCtrl.text.trim().nullIfEmpty,
        'party_category':   _catCtrl.text.trim().nullIfEmpty,
        'credit_limit':     _limitCtrl.text.trim().isEmpty
            ? null : double.tryParse(_limitCtrl.text.trim()),
        'credit_days':      int.tryParse(_daysCtrl.text.trim()) ?? 30,
        'is_credit_blocked':_creditBlocked,
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
      await _load();
      if (mounted) setState(() { _panelMode = 'none'; });
    } on DioException catch (e) {
      if (mounted) setState(() {
        _saveError = e.response?.data?['message'] ?? 'Save failed.';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Account'),
        content: const Text('This account will be soft-deleted and hidden. Continue?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
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
    setState(() { _panelMode = 'none'; _editNode = null; });
    await _load();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(
        child: Text(_error!, style: const TextStyle(color: AppColors.negative)));

    return Row(children: [
      SizedBox(width: 310, child: _leftPanel()),
      const VerticalDivider(width: 1, thickness: 1, color: AppColors.border),
      Expanded(child: _rightPanel()),
    ]);
  }

  // ── Left panel — tree ─────────────────────────────────────────────────────

  Widget _leftPanel() {
    final visible = _visibleNodes();
    return Column(children: [
      // Header
      Container(
        color: AppColors.surface,
        padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
        child: Row(children: [
          const Expanded(child: Text('Accounts',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary))),
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
        ]),
      ),
      const Divider(height: 1, color: AppColors.border),

      // Tree list
      Expanded(
        child: ListView.builder(
          itemCount: visible.length,
          itemBuilder: (_, i) {
            final item = visible[i];
            return _NodeRow(
              node:       item.node,
              depth:      item.depth,
              expanded:   _expanded.contains(item.node['id'] as String),
              hasChildren: (_childMap[item.node['id'] as String]?.isNotEmpty ?? false),
              isSelected: (_panelMode == 'edit' &&
                  _editNode?['id'] == item.node['id']),
              onToggle: () => setState(() {
                final id = item.node['id'] as String;
                if (_expanded.contains(id)) _expanded.remove(id);
                else _expanded.add(id);
              }),
              onEdit:  () => _openEdit(item.node),
              onAdd:   () => _openAdd(item.node),
            );
          },
        ),
      ),

      // Add root group button
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
              _saveError      = null;
              _clearForm();
            }),
          ),
        ),
      ),
    ]);
  }

  // ── Right panel ───────────────────────────────────────────────────────────

  Widget _rightPanel() {
    return switch (_panelMode) {
      'add'  => _formPanel(),
      'edit' => _formPanel(),
      _      => _emptyPanel(),
    };
  }

  Widget _emptyPanel() => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.account_tree_outlined, size: 48, color: AppColors.textDisabled),
      const SizedBox(height: 16),
      const Text('Select a group to add an account under it,',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
      const Text('or click ✏ on an existing account to edit it.',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
    ]),
  );

  Widget _formPanel() {
    final isAdd      = _panelMode == 'add';
    final isFixed    = _editNode?['is_system_fixed'] == true;
    final isParty    = _nature == 'Customer' || _nature == 'Supplier';
    final canDelete  = !isAdd && !isFixed &&
        (_childMap[_editNode?['id'] as String? ?? '']?.isEmpty ?? true);
    final parentName = isAdd
        ? (_addParent != null
            ? '${_addParent!['account_code']} — ${_addParent!['account_name']}'
            : '(None — Root Group)')
        : null;

    return Column(children: [
      // Panel header
      Container(
        color: AppColors.surface,
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(isAdd ? 'Add Account' : 'Account Details',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
            if (isAdd && parentName != null)
              Text('Under: $parentName',
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

            // Node type (only editable on new accounts)
            if (isAdd) ...[
              const _Label('Node Type *'),
              const SizedBox(height: 8),
              Row(children: [
                _TypeChip(label: 'Group', selected: !_postingAllowed,
                    onTap: () => setState(() => _postingAllowed = false)),
                const SizedBox(width: 10),
                _TypeChip(label: 'Ledger', selected: _postingAllowed,
                    onTap: () => setState(() => _postingAllowed = true)),
              ]),
              const SizedBox(height: 4),
              Text(
                _postingAllowed
                    ? 'Ledger: leaf node, transactions post here. No children allowed.'
                    : 'Group: organises accounts. Cannot post transactions directly.',
                style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 20),
            ],

            // Account Code
            const _Label('Account Code *'),
            const SizedBox(height: 6),
            if (_isAutoCode)
              _ReadOnlyField(_autoCode ?? 'Generating…', suffix: 'Auto')
            else
              TextField(
                controller: _codeCtrl,
                enabled: isAdd || !isFixed,
                decoration: const InputDecoration(isDense: true,
                    hintText: 'e.g. 6150'),
              ),
            const SizedBox(height: 16),

            // Account Name
            const _Label('Account Name *'),
            const SizedBox(height: 6),
            TextField(
              controller: _nameCtrl,
              enabled: !isFixed,
              decoration: const InputDecoration(isDense: true,
                  hintText: 'Enter account name'),
            ),
            const SizedBox(height: 16),

            // Nature + Currency row
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                const _Label('Nature *'),
                const SizedBox(height: 6),
                _addParent?['account_nature'] != null &&
                        _addParent!['account_nature'] != 'General'
                    ? _ReadOnlyField(_nature)
                    : DropdownButtonFormField<String>(
                        value: _nature,
                        decoration: const InputDecoration(isDense: true),
                        items: _natures.map((n) => DropdownMenuItem(
                            value: n, child: Text(n))).toList(),
                        onChanged: isFixed ? null
                            : (v) => setState(() => _nature = v!),
                      ),
              ])),
              const SizedBox(width: 16),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                const _Label('Currency'),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  value: _currencyId,
                  decoration: const InputDecoration(isDense: true,
                      hintText: 'Select…'),
                  items: _currencies.map((c) => DropdownMenuItem(
                    value: c['id'] as String,
                    child: Text('${c['currency_id']} — ${c['currency_name']}',
                        overflow: TextOverflow.ellipsis),
                  )).toList(),
                  onChanged: (v) => setState(() => _currencyId = v),
                ),
              ])),
            ]),

            // ── Party Details (Customer / Supplier only) ──────────────────
            if (isParty) ...[
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
                  style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                ),
                children: [
                  const SizedBox(height: 12),
                  const Divider(height: 1, color: AppColors.border),
                  const SizedBox(height: 16),

                  // Party Type
                  const _Label('Party Type'),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    value: _partyType,
                    decoration: const InputDecoration(isDense: true, hintText: 'Select…'),
                    items: _partyTypes.map((t) => DropdownMenuItem(
                        value: t, child: Text(t))).toList(),
                    onChanged: (v) => setState(() => _partyType = v),
                  ),
                  const SizedBox(height: 14),

                  // Contact + Phone
                  Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const _Label('Contact Person'),
                      const SizedBox(height: 6),
                      TextField(controller: _contactCtrl,
                          decoration: const InputDecoration(isDense: true)),
                    ])),
                    const SizedBox(width: 16),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
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

                  // Address
                  const _Label('Address Line 1'),
                  const SizedBox(height: 6),
                  TextField(controller: _addr1Ctrl,
                      decoration: const InputDecoration(isDense: true)),
                  const SizedBox(height: 10),
                  TextField(controller: _addr2Ctrl,
                      decoration: const InputDecoration(isDense: true,
                          hintText: 'Address Line 2')),
                  const SizedBox(height: 14),

                  // Country + City
                  Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const _Label('Country'),
                      const SizedBox(height: 6),
                      DropdownButtonFormField<String>(
                        value: _countryId,
                        decoration: const InputDecoration(isDense: true, hintText: 'Select…'),
                        items: _countries.map((c) => DropdownMenuItem(
                            value: c['id'] as String,
                            child: Text(c['country_name'] as String,
                                overflow: TextOverflow.ellipsis))).toList(),
                        onChanged: (v) {
                          setState(() { _countryId = v; _cityId = null; _cities = []; });
                          if (v != null) _loadCities(v);
                        },
                      ),
                    ])),
                    const SizedBox(width: 16),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const _Label('City'),
                      const SizedBox(height: 6),
                      DropdownButtonFormField<String>(
                        value: _cityId,
                        decoration: const InputDecoration(isDense: true, hintText: 'Select…'),
                        items: _cities.map((c) => DropdownMenuItem(
                            value: c['id'] as String,
                            child: Text(c['city_name'] as String,
                                overflow: TextOverflow.ellipsis))).toList(),
                        onChanged: (v) => setState(() => _cityId = v),
                      ),
                    ])),
                  ]),
                  const SizedBox(height: 14),

                  // Tax ID
                  const _Label('Tax ID (TVA / TIN / GSTIN)'),
                  const SizedBox(height: 6),
                  TextField(controller: _taxIdCtrl,
                      decoration: const InputDecoration(isDense: true)),
                  const SizedBox(height: 14),

                  // Category + Credit Days + Credit Limit
                  Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const _Label('Category'),
                      const SizedBox(height: 6),
                      TextField(controller: _catCtrl,
                          decoration: const InputDecoration(isDense: true,
                              hintText: 'e.g. Wholesale')),
                    ])),
                    const SizedBox(width: 12),
                    SizedBox(width: 90, child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const _Label('Credit Days'),
                      const SizedBox(height: 6),
                      TextField(controller: _daysCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(isDense: true)),
                    ])),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const _Label('Credit Limit'),
                      const SizedBox(height: 6),
                      TextField(controller: _limitCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(isDense: true,
                              hintText: '0.00')),
                    ])),
                  ]),
                  const SizedBox(height: 14),

                  // Credit Blocked
                  Row(children: [
                    Checkbox(
                      value: _creditBlocked,
                      onChanged: (v) => setState(() => _creditBlocked = v!),
                    ),
                    const Text('Credit Blocked',
                        style: TextStyle(fontSize: 13, color: AppColors.textPrimary)),
                  ]),
                ],
              ),
            ],

            if (_saveError != null) ...[
              const SizedBox(height: 16),
              Text(_saveError!,
                  style: const TextStyle(color: AppColors.negative, fontSize: 13)),
            ],

            const SizedBox(height: 24),
            if (!isFixed)
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                OutlinedButton(
                  onPressed: () => setState(() => _panelMode = 'none'),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2,
                              color: Colors.white))
                      : Text(isAdd ? 'Save Account' : 'Save Changes'),
                ),
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
  final int     depth;
  final bool    expanded;
  final bool    hasChildren;
  final bool    isSelected;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onAdd;

  const _NodeRow({
    required this.node,
    required this.depth,
    required this.expanded,
    required this.hasChildren,
    required this.isSelected,
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
    final node      = widget.node;
    final isFixed   = node['is_system_fixed'] == true;
    final isLeaf    = node['posting_allowed'] == true;
    final nature    = node['account_nature'] as String? ?? 'General';
    final natureColor = _natureColors[nature];

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit:  (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: widget.onEdit,
        child: Container(
          height: 36,
          color: widget.isSelected
              ? const Color(0xFFEAF0FB)
              : _hovered ? AppColors.surfaceVariant : null,
          padding: EdgeInsets.only(left: 8.0 + widget.depth * 16.0, right: 8),
          child: Row(children: [
            // Expand/collapse toggle
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

            // Node icon
            Icon(
              isLeaf ? Icons.description_outlined : Icons.folder_outlined,
              size: 15,
              color: isFixed ? AppColors.textDisabled : AppColors.textSecondary,
            ),
            const SizedBox(width: 6),

            // Account code
            Text(
              node['account_code'] as String? ?? '',
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: isFixed ? AppColors.textDisabled : AppColors.textSecondary,
              ),
            ),
            const SizedBox(width: 8),

            // Account name
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

            // Nature badge
            if (natureColor != null && _hovered == false && !widget.isSelected)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: natureColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(nature,
                    style: TextStyle(fontSize: 10, color: natureColor,
                        fontWeight: FontWeight.w600)),
              ),

            // Lock icon for fixed accounts
            if (isFixed)
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(Icons.lock_outline, size: 13, color: AppColors.textDisabled),
              ),

            // Hover actions
            if (_hovered) ...[
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 15),
                tooltip: 'Edit',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: widget.onEdit,
              ),
              if (!isLeaf)
                IconButton(
                  icon: const Icon(Icons.add, size: 15),
                  tooltip: 'Add account under this group',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: widget.onAdd,
                ),
            ],
          ]),
        ),
      ),
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
  final String label;
  final bool   selected;
  final VoidCallback onTap;
  const _TypeChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(6),
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
            width: selected ? 2 : 1),
        borderRadius: BorderRadius.circular(6),
        color: selected ? const Color(0xFFEAF0FB) : AppColors.surface,
      ),
      child: Text(label, style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: selected ? AppColors.primary : AppColors.textSecondary)),
    ),
  );
}

class _ReadOnlyField extends StatelessWidget {
  final String value;
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
          style: const TextStyle(fontSize: 13, color: AppColors.textSecondary))),
      if (suffix != null)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.border,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(suffix!,
              style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
        ),
    ]),
  );
}

// Extension helper
extension _NullIfEmpty on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
