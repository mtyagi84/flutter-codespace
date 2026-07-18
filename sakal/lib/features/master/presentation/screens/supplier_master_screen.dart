import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_presets.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/widgets/sakal_field_card.dart';
import '../../../../core/widgets/sakal_field_row.dart';

const _partyTypes = ['Individual', 'Company', 'Partnership', 'Government'];

class SupplierMasterScreen extends ConsumerStatefulWidget {
  const SupplierMasterScreen({super.key});

  @override
  ConsumerState<SupplierMasterScreen> createState() => _SupplierMasterScreenState();
}

class _SupplierMasterScreenState extends ConsumerState<SupplierMasterScreen> {
  List<Map<String, dynamic>> _suppliers  = [];
  List<Map<String, dynamic>> _filtered   = [];
  List<Map<String, dynamic>> _currencies = [];
  List<Map<String, dynamic>> _countries  = [];
  List<Map<String, dynamic>> _cities     = [];
  String? _supplierGroupId;

  bool    _loading = true;
  String? _error;
  bool    _saving  = false;
  String? _saveError;

  final _searchCtrl  = TextEditingController();
  Map<String, dynamic>? _selected;
  bool _isAdd = false;

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

  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      final accountsFuture = DioClient.instance.get(
        '/rim_accounts',
        queryParameters: {
          'client_id':      'eq.${session.clientId}',
          'company_id':     'eq.${session.companyId}',
          'account_nature': 'eq.Supplier',
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
        'account_nature': 'eq.Supplier',
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
          _suppliers       = List<Map<String, dynamic>>.from(accountsRes.data as List);
          _supplierGroupId = groups.isEmpty ? null : groups.first['id'] as String;
          _currencies      = currencies;
          _countries       = countries;
          _totalCount      = _parseTotal(accountsRes) ?? _suppliers.length;
          _loading         = false;
        });
        _applyFilter();
      }
    } on DioException {
      if (mounted) setState(() { _loading = false; _error = 'Could not load suppliers.'; });
    }
  }

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
      final res = await DioClient.instance.post('/rpc/fn_next_account_code', data: {
        'p_client_id':  session.clientId,
        'p_company_id': session.companyId,
        'p_parent_id':  parentId,
      });
      return res.data as String?;
    } on DioException { return null; }
  }

  void _applyFilter() {
    final q = _searchCtrl.text.toLowerCase();
    if (q.isNotEmpty && !_showAll) {
      setState(() => _showAll = true);
      _load();
      return;
    }
    setState(() {
      _filtered = q.isEmpty
          ? List.from(_suppliers)
          : _suppliers.where((s) =>
              (s['account_name'] as String).toLowerCase().contains(q) ||
              (s['account_code'] as String).toLowerCase().contains(q) ||
              (s['phone'] as String? ?? '').toLowerCase().contains(q) ||
              (s['email'] as String? ?? '').toLowerCase().contains(q),
            ).toList();
    });
  }

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
      _partyType        = row['party_type']          as String?;
      _currencyId       = row['account_currency_id'] as String?;
      _countryId        = row['country_id']          as String?;
      _cityId           = row['city_id']             as String?;
      _creditBlocked    = row['is_credit_blocked']   as bool? ?? false;
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
    if (name.isEmpty) { setState(() => _saveError = 'Supplier name is required.'); return; }

    final session = ref.read(sessionProvider)!;
    setState(() { _saving = true; _saveError = null; });
    try {
      if (_isAdd) {
        if (_supplierGroupId == null) {
          setState(() { _saveError = 'Supplier group not found. Please seed the Chart of Accounts first.'; _saving = false; });
          return;
        }
        final code = await _fetchNextCode(_supplierGroupId!);
        await DioClient.instance.post('/rim_accounts', data: _buildPayload(session, name,
            code: code, parentId: _supplierGroupId));
      } else {
        await DioClient.instance.patch(
          '/rim_accounts',
          queryParameters: {'id': 'eq.${_selected!['id']}'},
          data: _buildPayload(session, name),
        );
      }
      // accountsProvider (shared account picker cache) is fetched once per
      // app session — invalidate so a newly created supplier shows up
      // elsewhere (Purchase, GRN, Finance Voucher, ...) without a
      // logout/login.
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
    'account_name':      name,
    'account_nature':    'Supplier',
    'posting_allowed':   true,
    'is_system_fixed':   false,
    'account_currency_id': _currencyId,
    'party_type':        _partyType,
    'contact_person':    _contactCtrl.text.trim().nullIfEmpty,
    'phone':             _phoneCtrl.text.trim().nullIfEmpty,
    'email':             _emailCtrl.text.trim().nullIfEmpty,
    'address_line1':     _addr1Ctrl.text.trim().nullIfEmpty,
    'address_line2':     _addr2Ctrl.text.trim().nullIfEmpty,
    'country_id':        _countryId,
    'city_id':           _cityId,
    'tax_id':            _taxIdCtrl.text.trim().nullIfEmpty,
    'party_category':    _catCtrl.text.trim().nullIfEmpty,
    'credit_limit':      _limitCtrl.text.trim().isEmpty
        ? null : double.tryParse(_limitCtrl.text.trim()),
    'credit_days':       int.tryParse(_daysCtrl.text.trim()) ?? 30,
    'is_credit_blocked': _creditBlocked,
    'client_id':         session.clientId,
    'company_id':        session.companyId,
    'updated_by':        session.userId,
    if (parentId != null) ...{
      'accounting_std': 'OHADA',
      'created_by':     session.userId,
    },
  };

  Future<void> _delete(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Supplier'),
        content: const Text('Supplier will be soft-deleted. Continue?'),
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

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) { return Center(
        child: Text(_error!, style: const TextStyle(color: AppColors.negative))); }

    final showPanel = _isAdd || _selected != null;
    final mobile = Responsive.isMobile(context);

    if (mobile) {
      // On mobile: list OR form, never side by side
      if (showPanel) return _formPanel(mobile);
      return _listPanel();
    }

    return Row(children: [
      SizedBox(width: 320, child: _listPanel()),
      if (showPanel) ...[
        const VerticalDivider(width: 1, thickness: 1, color: AppColors.border),
        Expanded(child: _formPanel(mobile)),
      ],
    ]);
  }

  Widget _listPanel() {
    final offline = ref.watch(sessionProvider)?.offlineMode ?? false;
    return Column(children: [
    Container(
      color: AppColors.surface,
      padding: const EdgeInsets.all(16),
      child: Row(children: [
        const Expanded(child: Text('Suppliers',
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
      child: SakalFieldCard(
        label: 'Search',
        editable: true,
        child: TextField(
          controller: _searchCtrl,
          decoration: SakalFieldCard.bareDecoration.copyWith(
            hintText: 'Search name, code, phone…',
            prefixIcon: const Icon(Icons.search, size: 18),
          ),
          style: SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider)),
        ),
      ),
    ),
    const Divider(height: 1, color: AppColors.border),
    Expanded(
      child: _filtered.isEmpty
          ? const Center(child: Text('No suppliers found.',
              style: TextStyle(color: AppColors.textSecondary)))
          : ListView.builder(
              itemCount: _filtered.length,
              itemBuilder: (_, i) {
                final row = _filtered[i];
                final isSelected = _selected?['id'] == row['id'];
                return InkWell(
                  onTap: () => _openEdit(row),
                  child: Container(
                    color: isSelected
                        ? ThemePresetConfig.all[ref.watch(themePresetProvider)]!.accent.withValues(alpha: 0.15)
                        : null,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    child: Row(children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: AppColors.info.withValues(alpha: 0.1),
                        child: Text(
                          (row['account_name'] as String).isNotEmpty
                              ? (row['account_name'] as String)[0].toUpperCase()
                              : '?',
                          style: const TextStyle(fontSize: 13,
                              color: AppColors.info,
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
                          [row['account_code'], row['phone']]
                              .where((s) => s != null && (s as String).isNotEmpty)
                              .join(' · '),
                          style: const TextStyle(fontSize: 11,
                              color: AppColors.textSecondary),
                        ),
                      ])),
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

  Widget _formTitleBlock(bool isAdd) => Text(isAdd ? 'New Supplier' : 'Edit Supplier',
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
          color: AppColors.textPrimary));

  Widget _formCloseButton() => IconButton(
        icon: const Icon(Icons.close, size: 18),
        onPressed: () => setState(() { _selected = null; _isAdd = false; }),
      );

  Widget _formActionButtons(bool isAdd, Map<String, dynamic>? row, bool offline) =>
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (!isAdd && row != null && !offline)
          TextButton.icon(
            icon: const Icon(Icons.delete_outline, size: 16),
            label: const Text('Delete'),
            style: TextButton.styleFrom(foregroundColor: AppColors.negative),
            onPressed: () => _delete(row['id'] as String),
          ),
        if (!offline)
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : Text(isAdd ? 'Create Supplier' : 'Save Changes'),
          ),
      ]);

  Widget _formPanel(bool mobile) {
    final isAdd = _isAdd;
    final row   = _selected;
    final offline = ref.watch(sessionProvider)?.offlineMode ?? false;
    final isCompact = ref.watch(isCompactDensityProvider);
    return Column(children: [
      Container(
        color: AppColors.surface,
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
        child: mobile
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: _formTitleBlock(isAdd)),
                  _formCloseButton(),
                ]),
                const SizedBox(height: 10),
                _formActionButtons(isAdd, row, offline),
              ])
            : Row(children: [
                Expanded(child: _formTitleBlock(isAdd)),
                _formActionButtons(isAdd, row, offline),
                const SizedBox(width: 8),
                _formCloseButton(),
              ]),
      ),
      const Divider(height: 1, color: AppColors.border),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (!isAdd && row != null) ...[
              SakalFieldCard.readOnly(label: 'Account Code', value: row['account_code'] as String? ?? ''),
              const SizedBox(height: 16),
            ],
            SakalFieldCard(
              label: 'Supplier Name',
              required: true,
              editable: true,
              child: TextField(
                controller: _nameCtrl,
                decoration: SakalFieldCard.bareDecoration.copyWith(hintText: 'Enter supplier name'),
                style: SakalFieldCard.valueTextStyle(isCompact),
              ),
            ),
            const SizedBox(height: 16),
            SakalFieldCard(
              label: 'Ledger Currency',
              editable: true,
              child: DropdownButtonFormField<String>(
                initialValue: _currencyId,
                isExpanded: true, isDense: true, itemHeight: null,
                decoration: SakalFieldCard.bareDecoration,
                style: SakalFieldCard.valueTextStyle(isCompact),
                items: _currencies.map((c) => DropdownMenuItem(
                  value: c['id'] as String,
                  child: Text('${c['currency_id']} — ${c['currency_name']}',
                      overflow: TextOverflow.ellipsis),
                )).toList(),
                onChanged: (v) => setState(() => _currencyId = v),
              ),
            ),
            const SizedBox(height: 20),
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
                // Party Type
                SakalFieldCard(
                  label: 'Party Type',
                  editable: true,
                  child: DropdownButtonFormField<String>(
                    initialValue: _partyType,
                    isExpanded: true, isDense: true, itemHeight: null,
                    decoration: SakalFieldCard.bareDecoration,
                    style: SakalFieldCard.valueTextStyle(isCompact),
                    items: _partyTypes.map((t) => DropdownMenuItem(
                        value: t, child: Text(t))).toList(),
                    onChanged: (v) => setState(() => _partyType = v),
                  ),
                ),
                const SizedBox(height: 14),
                SakalFieldRow(isMobile: mobile, children: [
                  SakalFieldCard(
                    label: 'Contact Person',
                    editable: true,
                    child: TextField(controller: _contactCtrl,
                        decoration: SakalFieldCard.bareDecoration,
                        style: SakalFieldCard.valueTextStyle(isCompact)),
                  ),
                  SakalFieldCard(
                    label: 'Phone',
                    editable: true,
                    child: TextField(controller: _phoneCtrl,
                        decoration: SakalFieldCard.bareDecoration,
                        style: SakalFieldCard.valueTextStyle(isCompact)),
                  ),
                ]),
                const SizedBox(height: 14),
                SakalFieldCard(
                  label: 'Email',
                  editable: true,
                  child: TextField(controller: _emailCtrl,
                      decoration: SakalFieldCard.bareDecoration,
                      style: SakalFieldCard.valueTextStyle(isCompact)),
                ),
                const SizedBox(height: 14),
                SakalFieldCard(
                  label: 'Address Line 1',
                  editable: true,
                  child: TextField(controller: _addr1Ctrl,
                      decoration: SakalFieldCard.bareDecoration,
                      style: SakalFieldCard.valueTextStyle(isCompact)),
                ),
                const SizedBox(height: 10),
                SakalFieldCard(
                  label: 'Address Line 2',
                  editable: true,
                  child: TextField(controller: _addr2Ctrl,
                      decoration: SakalFieldCard.bareDecoration,
                      style: SakalFieldCard.valueTextStyle(isCompact)),
                ),
                const SizedBox(height: 14),
                SakalFieldRow(isMobile: mobile, children: [
                  SakalFieldCard(
                    label: 'Country',
                    editable: true,
                    child: DropdownButtonFormField<String>(
                      initialValue: _countryId,
                      isExpanded: true, isDense: true, itemHeight: null,
                      decoration: SakalFieldCard.bareDecoration,
                      style: SakalFieldCard.valueTextStyle(isCompact),
                      items: _countries.map((c) => DropdownMenuItem(
                          value: c['id'] as String,
                          child: Text(c['country_name'] as String,
                              overflow: TextOverflow.ellipsis))).toList(),
                      onChanged: (v) {
                        setState(() { _countryId = v; _cityId = null; _cities = []; });
                        if (v != null) _loadCities(v);
                      },
                    ),
                  ),
                  SakalFieldCard(
                    label: 'City',
                    editable: true,
                    child: DropdownButtonFormField<String>(
                      initialValue: _cityId,
                      isExpanded: true, isDense: true, itemHeight: null,
                      decoration: SakalFieldCard.bareDecoration,
                      style: SakalFieldCard.valueTextStyle(isCompact),
                      items: _cities.map((c) => DropdownMenuItem(
                          value: c['id'] as String,
                          child: Text(c['city_name'] as String,
                              overflow: TextOverflow.ellipsis))).toList(),
                      onChanged: (v) => setState(() => _cityId = v),
                    ),
                  ),
                ]),
                const SizedBox(height: 14),
                SakalFieldCard(
                  label: 'Tax ID (TVA / TIN)',
                  editable: true,
                  child: TextField(controller: _taxIdCtrl,
                      decoration: SakalFieldCard.bareDecoration,
                      style: SakalFieldCard.valueTextStyle(isCompact)),
                ),
                const SizedBox(height: 14),
                SakalFieldRow(isMobile: mobile, children: [
                  SakalFieldCard(
                    label: 'Category',
                    editable: true,
                    child: TextField(controller: _catCtrl,
                        decoration: SakalFieldCard.bareDecoration.copyWith(hintText: 'e.g. Local / Imported'),
                        style: SakalFieldCard.valueTextStyle(isCompact)),
                  ),
                  SakalFieldCard(
                    label: 'Credit Days',
                    editable: true,
                    numeric: true,
                    child: TextField(controller: _daysCtrl,
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.right,
                        decoration: SakalFieldCard.bareDecoration,
                        style: SakalFieldCard.valueTextStyle(isCompact)),
                  ),
                  SakalFieldCard(
                    label: 'Credit Limit',
                    editable: true,
                    numeric: true,
                    child: TextField(controller: _limitCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        textAlign: TextAlign.right,
                        decoration: SakalFieldCard.bareDecoration.copyWith(hintText: '0.00'),
                        style: SakalFieldCard.valueTextStyle(isCompact)),
                  ),
                ]),
              ],
            ),
            if (_saveError != null) ...[
              const SizedBox(height: 16),
              Text(_saveError!,
                  style: const TextStyle(color: AppColors.negative, fontSize: 13)),
            ],
          ]),
        ),
      ),
    ]);
  }
}

extension _NullIfEmpty on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
