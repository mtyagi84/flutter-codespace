import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';

const _partyTypes = ['Individual', 'Company', 'Partnership', 'Government'];

class CustomerMasterScreen extends ConsumerStatefulWidget {
  const CustomerMasterScreen({super.key});

  @override
  ConsumerState<CustomerMasterScreen> createState() => _CustomerMasterScreenState();
}

class _CustomerMasterScreenState extends ConsumerState<CustomerMasterScreen> {
  List<Map<String, dynamic>> _customers  = [];
  List<Map<String, dynamic>> _filtered   = [];
  List<Map<String, dynamic>> _currencies = [];
  List<Map<String, dynamic>> _countries  = [];
  List<Map<String, dynamic>> _cities     = [];
  String?  _customerGroupId; // parent account for new customers

  bool    _loading = true;
  String? _error;
  bool    _saving  = false;
  String? _saveError;

  final _searchCtrl  = TextEditingController();
  Map<String, dynamic>? _selected; // currently selected customer
  bool _isAdd = false;

  // Form controllers
  final _nameCtrl    = TextEditingController();
  final _contactCtrl = TextEditingController();
  final _phoneCtrl   = TextEditingController();
  final _emailCtrl   = TextEditingController();
  final _addr1Ctrl   = TextEditingController();
  final _addr2Ctrl   = TextEditingController();
  final _taxIdCtrl   = TextEditingController();
  final _catCtrl     = TextEditingController();
  final _limitCtrl   = TextEditingController();
  final _daysCtrl    = TextEditingController();

  String? _partyType;
  String? _currencyId;
  String? _countryId;
  String? _cityId;
  bool    _creditBlocked = false;
  bool    _partyExpanded = true;

  static const int _pageSize = 25;
  int  _totalCount = 0;
  bool _showAll    = false;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_applyFilter);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    for (final c in [_nameCtrl, _contactCtrl, _phoneCtrl, _emailCtrl,
        _addr1Ctrl, _addr2Ctrl, _taxIdCtrl, _catCtrl, _limitCtrl, _daysCtrl]) {
      c.dispose();
    }
    super.dispose();
  }

  // ── Data ─────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      final accountsFuture = DioClient.instance.get(
        '/rim_accounts',
        queryParameters: {
          'client_id':      'eq.${session.clientId}',
          'company_id':     'eq.${session.companyId}',
          'account_nature': 'eq.Customer',
          'posting_allowed':'eq.true',
          'is_deleted':     'eq.false',
          'select':         '*',
          'order':          'account_name.asc',
          if (!_showAll) 'limit': '$_pageSize',
        },
        options: Options(headers: {'Prefer': 'count=exact'}),
      );
      final groupFuture = DioClient.instance.get('/rim_accounts', queryParameters: {
        'client_id':      'eq.${session.clientId}',
        'company_id':     'eq.${session.companyId}',
        'account_nature': 'eq.Customer',
        'posting_allowed':'eq.false',
        'is_deleted':     'eq.false',
        'select':         'id',
        'limit':          '1',
      });
      final currenciesFuture = ref.read(currenciesProvider.future);
      final countriesFuture  = ref.read(countriesProvider.future);

      final accountsRes = await accountsFuture;
      final groupRes    = await groupFuture;
      final currencies  = await currenciesFuture;
      final countries   = await countriesFuture;

      if (mounted) {
        final groups = List<Map<String, dynamic>>.from(groupRes.data as List);
        setState(() {
          _customers       = List<Map<String, dynamic>>.from(accountsRes.data as List);
          _customerGroupId = groups.isEmpty ? null : groups.first['id'] as String;
          _currencies      = currencies;
          _countries       = countries;
          _totalCount      = _parseTotal(accountsRes) ?? _customers.length;
          _loading         = false;
        });
        _applyFilter();
      }
    } on DioException {
      if (mounted) setState(() { _loading = false; _error = 'Could not load customers.'; });
    }
  }

  // PostgREST returns Content-Range: 0-24/342 with Prefer: count=exact
  int? _parseTotal(Response res) {
    final raw = res.headers.value('content-range');
    if (raw == null) return null;
    return int.tryParse(raw.split('/').last.trim());
  }

  Future<void> _loadCities(String countryId) async {
    final session = ref.read(sessionProvider)!;
    try {
      final res = await DioClient.instance.get('/rim_cities', queryParameters: {
        'client_id':  'eq.${session.clientId}',
        'company_id': 'eq.${session.companyId}',
        'country_id': 'eq.$countryId',
        'select':     'id,city_name',
        'order':      'city_name.asc',
      });
      if (mounted) setState(() => _cities = List<Map<String, dynamic>>.from(res.data as List));
    } on DioException { /* silent */ }
  }

  Future<String?> _fetchNextCode(String parentId) async {
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
      return res.data as String?;
    } on DioException { return null; }
  }

  void _applyFilter() {
    final q = _searchCtrl.text.toLowerCase();
    // First search keystroke while paginated → reload all records from server
    if (q.isNotEmpty && !_showAll) {
      setState(() => _showAll = true);
      _load();
      return;
    }
    setState(() {
      _filtered = q.isEmpty
          ? List.from(_customers)
          : _customers.where((c) =>
              (c['account_name'] as String).toLowerCase().contains(q) ||
              (c['account_code'] as String).toLowerCase().contains(q) ||
              (c['phone'] as String? ?? '').toLowerCase().contains(q) ||
              (c['email'] as String? ?? '').toLowerCase().contains(q),
            ).toList();
    });
  }

  // ── Panel state ───────────────────────────────────────────────────────────

  void _openAdd() {
    setState(() {
      _isAdd = true; _selected = null; _saveError = null;
      _partyExpanded = true;
      _clearForm(); _daysCtrl.text = '30';
    });
  }

  void _openEdit(Map<String, dynamic> row) {
    setState(() {
      _isAdd = false; _selected = row; _saveError = null;
      _partyExpanded = false;
      _nameCtrl.text    = row['account_name']   as String? ?? '';
      _contactCtrl.text = row['contact_person'] as String? ?? '';
      _phoneCtrl.text   = row['phone']          as String? ?? '';
      _emailCtrl.text   = row['email']          as String? ?? '';
      _addr1Ctrl.text   = row['address_line1']  as String? ?? '';
      _addr2Ctrl.text   = row['address_line2']  as String? ?? '';
      _taxIdCtrl.text   = row['tax_id']         as String? ?? '';
      _catCtrl.text     = row['party_category'] as String? ?? '';
      _limitCtrl.text   = row['credit_limit'] != null
          ? row['credit_limit'].toString() : '';
      _daysCtrl.text    = (row['credit_days'] ?? 30).toString();
      _partyType        = row['party_type']  as String?;
      _currencyId       = row['account_currency_id'] as String?;
      _countryId        = row['country_id']  as String?;
      _cityId           = row['city_id']     as String?;
      _creditBlocked    = row['is_credit_blocked'] as bool? ?? false;
      _cities           = [];
    });
    if (_countryId != null) _loadCities(_countryId!);
  }

  void _clearForm() {
    for (final c in [_nameCtrl, _contactCtrl, _phoneCtrl, _emailCtrl,
        _addr1Ctrl, _addr2Ctrl, _taxIdCtrl, _catCtrl, _limitCtrl, _daysCtrl]) {
      c.clear();
    }
    _partyType = null; _currencyId = null;
    _countryId = null; _cityId = null;
    _creditBlocked = false; _cities = [];
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) { setState(() => _saveError = 'Customer name is required.'); return; }

    final session = ref.read(sessionProvider)!;
    setState(() { _saving = true; _saveError = null; });

    try {
      if (_isAdd) {
        if (_customerGroupId == null) {
          setState(() { _saveError = 'Customer group not found. Please seed the Chart of Accounts first.'; _saving = false; });
          return;
        }
        final code = await _fetchNextCode(_customerGroupId!);
        await DioClient.instance.post('/rim_accounts', data: _buildPayload(session, name,
            code: code, parentId: _customerGroupId));
      } else {
        await DioClient.instance.patch(
          '/rim_accounts',
          queryParameters: {'id': 'eq.${_selected!['id']}'},
          data: _buildPayload(session, name),
        );
      }
      // accountsProvider (shared account picker cache) is fetched once per
      // app session — invalidate so a newly created customer shows up
      // elsewhere (Sales, Finance Voucher, ...) without a logout/login.
      ref.invalidate(accountsProvider);
      await _load();
      if (mounted) setState(() { _isAdd = false; _selected = null; });
    } on DioException catch (e) {
      if (mounted) { setState(() {
        _saveError = e.response?.data?['message'] ?? 'Save failed.';
      }); }
    } finally {
      if (mounted) { setState(() => _saving = false); }
    }
  }

  Map<String, dynamic> _buildPayload(UserSession session, String name,
      {String? code, String? parentId}) => {
    if (parentId != null) 'parent_id': parentId,
    if (code != null) 'account_code': code,
    'account_name':    name,
    'account_nature':  'Customer',
    'posting_allowed': true,
    'is_system_fixed': false,
    'account_currency_id': _currencyId,
    'party_type':      _partyType,
    'contact_person':  _contactCtrl.text.trim().nullIfEmpty,
    'phone':           _phoneCtrl.text.trim().nullIfEmpty,
    'email':           _emailCtrl.text.trim().nullIfEmpty,
    'address_line1':   _addr1Ctrl.text.trim().nullIfEmpty,
    'address_line2':   _addr2Ctrl.text.trim().nullIfEmpty,
    'country_id':      _countryId,
    'city_id':         _cityId,
    'tax_id':          _taxIdCtrl.text.trim().nullIfEmpty,
    'party_category':  _catCtrl.text.trim().nullIfEmpty,
    'credit_limit':    _limitCtrl.text.trim().isEmpty
        ? null : double.tryParse(_limitCtrl.text.trim()),
    'credit_days':     int.tryParse(_daysCtrl.text.trim()) ?? 30,
    'is_credit_blocked': _creditBlocked,
    'client_id':       session.clientId,
    'company_id':      session.companyId,
    'updated_by':      session.userId,
    if (parentId != null) ...{
      'accounting_std': 'OHADA', // derived from seeded data
      'created_by':    session.userId,
    },
  };

  Future<void> _delete(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Customer'),
        content: const Text('Customer will be soft-deleted. Continue?'),
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
    ref.invalidate(accountsProvider);
    setState(() { _selected = null; _isAdd = false; });
    await _load();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) { return Center(
        child: Text(_error!, style: const TextStyle(color: AppColors.negative))); }

    final showPanel = _isAdd || _selected != null;

    if (Responsive.isMobile(context)) {
      // On mobile: list OR form, never side by side
      if (showPanel) return _formPanel();
      return _listPanel();
    }

    return Row(children: [
      SizedBox(width: 320, child: _listPanel()),
      if (showPanel) ...[
        const VerticalDivider(width: 1, thickness: 1, color: AppColors.border),
        Expanded(child: _formPanel()),
      ],
    ]);
  }

  // ── List panel ────────────────────────────────────────────────────────────

  Widget _listPanel() {
    final offline = ref.watch(sessionProvider)?.offlineMode ?? false;
    return Column(children: [
    Container(
      color: AppColors.surface,
      padding: const EdgeInsets.all(16),
      child: Row(children: [
        const Expanded(child: Text('Customers',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
                color: AppColors.textPrimary))),
        if (!offline)
          FilledButton.icon(
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add'),
            onPressed: _openAdd,
          ),
      ]),
    ),
    Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: _searchCtrl,
        decoration: const InputDecoration(
          isDense: true,
          hintText: 'Search name, code, phone…',
          prefixIcon: Icon(Icons.search, size: 18),
        ),
      ),
    ),
    const Divider(height: 1, color: AppColors.border),
    Expanded(
      child: _filtered.isEmpty
          ? const Center(child: Text('No customers found.',
              style: TextStyle(color: AppColors.textSecondary)))
          : ListView.builder(
              itemCount: _filtered.length,
              itemBuilder: (_, i) {
                final row = _filtered[i];
                final isSelected = _selected?['id'] == row['id'];
                return InkWell(
                  onTap: () => _openEdit(row),
                  child: Container(
                    color: isSelected ? const Color(0xFFEAF0FB) : null,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    child: Row(children: [
                      // Avatar initials
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: AppColors.primary.withValues(alpha: 0.1),
                        child: Text(
                          (row['account_name'] as String).isNotEmpty
                              ? (row['account_name'] as String)[0].toUpperCase()
                              : '?',
                          style: const TextStyle(fontSize: 13,
                              color: AppColors.primary,
                              fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(row['account_name'] as String,
                            style: const TextStyle(fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary)),
                        Text(
                          [
                            row['account_code'] as String?,
                            row['phone'] as String?,
                          ].where((s) => s != null && s.isNotEmpty)
                              .join(' · '),
                          style: const TextStyle(fontSize: 11,
                              color: AppColors.textSecondary),
                        ),
                      ])),
                      if (!(row['is_active'] as bool? ?? true))
                        const Icon(Icons.block, size: 14, color: AppColors.negative),
                    ]),
                  ),
                );
              },
            ),
    ),
    if (!_showAll && _totalCount > _pageSize) _paginationFooter(),
  ]);
  }

  Widget _paginationFooter() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    decoration: const BoxDecoration(
      color: AppColors.surface,
      border: Border(top: BorderSide(color: AppColors.border)),
    ),
    child: Row(children: [
      Text(
        'Showing $_pageSize of $_totalCount',
        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
      ),
      const Spacer(),
      TextButton(
        onPressed: () { setState(() => _showAll = true); _load(); },
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: const Text('Show All', style: TextStyle(fontSize: 12)),
      ),
    ]),
  );

  // ── Form panel ────────────────────────────────────────────────────────────

  Widget _formPanel() {
    final isAdd = _isAdd;
    final row   = _selected;
    return Column(children: [
      Container(
        color: AppColors.surface,
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
        child: Row(children: [
          Expanded(child: Text(isAdd ? 'New Customer' : 'Edit Customer',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary))),
          if (!isAdd && row != null)
            TextButton.icon(
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('Delete'),
              style: TextButton.styleFrom(foregroundColor: AppColors.negative),
              onPressed: () => _delete(row['id'] as String),
            ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() { _selected = null; _isAdd = false; }),
          ),
        ]),
      ),
      const Divider(height: 1, color: AppColors.border),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Account code (read-only on edit, auto on add)
            if (!isAdd && row != null) ...[
              const _Label('Account Code'),
              const SizedBox(height: 6),
              _ReadOnlyField(row['account_code'] as String? ?? ''),
              const SizedBox(height: 16),
            ],

            // Name
            const _Label('Customer Name *'),
            const SizedBox(height: 6),
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(isDense: true,
                  hintText: 'Enter customer name'),
            ),
            const SizedBox(height: 16),

            // Currency
            const _Label('Ledger Currency'),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              initialValue: _currencyId,
              decoration: const InputDecoration(isDense: true, hintText: 'Select…'),
              items: _currencies.map((c) => DropdownMenuItem(
                value: c['id'] as String,
                child: Text('${c['currency_id']} — ${c['currency_name']}',
                    overflow: TextOverflow.ellipsis),
              )).toList(),
              onChanged: (v) => setState(() => _currencyId = v),
            ),
            const SizedBox(height: 20),

            // Party Details (always expanded for customer screen)
            ExpansionTile(
              initiallyExpanded: _partyExpanded,
              onExpansionChanged: (v) => setState(() => _partyExpanded = v),
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: const Text('Party Details',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary)),
              children: [
                const SizedBox(height: 12),
                const Divider(height: 1, color: AppColors.border),
                const SizedBox(height: 16),
                ..._partyFields(),
              ],
            ),

            if (_saveError != null) ...[
              const SizedBox(height: 16),
              Text(_saveError!,
                  style: const TextStyle(color: AppColors.negative, fontSize: 13)),
            ],
            const SizedBox(height: 24),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              OutlinedButton(
                onPressed: () => setState(() { _selected = null; _isAdd = false; }),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text(isAdd ? 'Create Customer' : 'Save Changes'),
              ),
            ]),
          ]),
        ),
      ),
    ]);
  }

  List<Widget> _partyFields() {
    final mobile = Responsive.isMobile(context);
    return [
      // Party Type
      const _Label('Party Type'),
      const SizedBox(height: 6),
      DropdownButtonFormField<String>(
        initialValue: _partyType,
        decoration: const InputDecoration(isDense: true, hintText: 'Select…'),
        items: _partyTypes.map((t) => DropdownMenuItem(
            value: t, child: Text(t))).toList(),
        onChanged: (v) => setState(() => _partyType = v),
      ),
      const SizedBox(height: 14),

      // Contact + Phone
      if (mobile) ...[
        const _Label('Contact Person'),
        const SizedBox(height: 6),
        TextField(controller: _contactCtrl,
            decoration: const InputDecoration(isDense: true)),
        const SizedBox(height: 14),
        const _Label('Phone'),
        const SizedBox(height: 6),
        TextField(controller: _phoneCtrl,
            decoration: const InputDecoration(isDense: true)),
      ] else
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const _Label('Contact Person'),
            const SizedBox(height: 6),
            TextField(controller: _contactCtrl,
                decoration: const InputDecoration(isDense: true)),
          ])),
          const SizedBox(width: 16),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const _Label('Phone'),
            const SizedBox(height: 6),
            TextField(controller: _phoneCtrl,
                decoration: const InputDecoration(isDense: true)),
          ])),
        ]),
      const SizedBox(height: 14),

      const _Label('Email'),
      const SizedBox(height: 6),
      TextField(controller: _emailCtrl,
          decoration: const InputDecoration(isDense: true)),
      const SizedBox(height: 14),

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
      if (mobile) ...[
        const _Label('Country'),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          initialValue: _countryId,
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
        const SizedBox(height: 14),
        const _Label('City'),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          initialValue: _cityId,
          decoration: const InputDecoration(isDense: true, hintText: 'Select…'),
          items: _cities.map((c) => DropdownMenuItem(
              value: c['id'] as String,
              child: Text(c['city_name'] as String,
                  overflow: TextOverflow.ellipsis))).toList(),
          onChanged: (v) => setState(() => _cityId = v),
        ),
      ] else
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const _Label('Country'),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              initialValue: _countryId,
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
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const _Label('City'),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              initialValue: _cityId,
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

      const _Label('Tax ID (TVA / TIN / GSTIN)'),
      const SizedBox(height: 6),
      TextField(controller: _taxIdCtrl,
          decoration: const InputDecoration(isDense: true)),
      const SizedBox(height: 14),

      // Category + Credit Days + Credit Limit
      if (mobile) ...[
        const _Label('Category'),
        const SizedBox(height: 6),
        TextField(controller: _catCtrl,
            decoration: const InputDecoration(isDense: true,
                hintText: 'e.g. Wholesale')),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const _Label('Credit Days'),
            const SizedBox(height: 6),
            TextField(controller: _daysCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(isDense: true)),
          ])),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const _Label('Credit Limit'),
            const SizedBox(height: 6),
            TextField(controller: _limitCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(isDense: true, hintText: '0.00')),
          ])),
        ]),
      ] else
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const _Label('Credit Limit'),
            const SizedBox(height: 6),
            TextField(controller: _limitCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(isDense: true, hintText: '0.00')),
          ])),
        ]),
      const SizedBox(height: 14),

      Row(children: [
        Checkbox(
          value: _creditBlocked,
          onChanged: (v) => setState(() => _creditBlocked = v!),
        ),
        const Text('Credit Blocked',
            style: TextStyle(fontSize: 13, color: AppColors.textPrimary)),
      ]),
    ];
  }
}

// ── Shared small widgets ──────────────────────────────────────────────────────

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
          color: AppColors.textPrimary));
}

class _ReadOnlyField extends StatelessWidget {
  final String value;
  const _ReadOnlyField(this.value);
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: AppColors.surfaceVariant,
      border: Border.all(color: AppColors.border),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(value,
        style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
  );
}

extension _NullIfEmpty on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
