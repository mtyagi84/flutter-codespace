import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_presets.dart';
import '../../../../core/utils/account_transaction_check.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/sakal_autocomplete.dart';
import '../../../../core/widgets/sakal_field_card.dart';
import '../../../../core/widgets/sakal_field_row.dart';
import '../../../../core/widgets/sakal_formatted_number_field.dart';

const _partyTypes = ['Individual', 'Company', 'Partnership', 'Government'];

class CustomerMasterScreen extends ConsumerStatefulWidget {
  const CustomerMasterScreen({super.key});

  @override
  ConsumerState<CustomerMasterScreen> createState() => _CustomerMasterScreenState();
}

class _CustomerMasterScreenState extends ConsumerState<CustomerMasterScreen>
    with ScreenPermissionMixin<CustomerMasterScreen> {
  @override String get screenName => RouteNames.customerMaster;

  List<Map<String, dynamic>> _customers  = [];
  List<Map<String, dynamic>> _filtered   = [];
  List<Map<String, dynamic>> _currencies = [];
  List<Map<String, dynamic>> _countries  = [];
  List<Map<String, dynamic>> _divisions  = [];
  List<Map<String, dynamic>> _cities     = [];
  List<Map<String, dynamic>> _groups     = []; // Customer group nodes (posting_allowed=false)
  List<Map<String, dynamic>> _categories = [];
  String?  _customerGroupId; // selected parent group — user-editable, not fixed
  String   _groupDisplay = '';
  bool?    _hasTransactions; // null = not yet checked (Add mode, or still loading)

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
  final _limitCtrl   = TextEditingController();
  final _daysCtrl    = TextEditingController();

  String? _partyType;
  String? _currencyId;
  String? _countryId;
  String? _divisionId;
  String? _cityId;
  String? _category;
  bool    _creditBlocked = false;
  bool    _isActive      = true;
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
        _addr1Ctrl, _addr2Ctrl, _taxIdCtrl, _limitCtrl, _daysCtrl]) {
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
      // All Customer group (posting_allowed=false) nodes, at any nesting
      // depth — feeds the Parent Group picker AND the list row's group-name
      // resolution. Previously only the FIRST such row was ever fetched
      // and silently used for every new customer, with no way to pick a
      // different (possibly nested) group.
      final groupFuture = DioClient.instance.get('/rim_accounts', queryParameters: {
        'client_id':      'eq.${session.clientId}',
        'company_id':     'eq.${session.companyId}',
        'account_nature': 'eq.Customer',
        'posting_allowed':'eq.false',
        'is_deleted':     'eq.false',
        'select':         'id,account_code,account_name',
        'order':          'account_code.asc',
      });
      final currenciesFuture  = ref.read(currenciesProvider.future);
      final countriesFuture   = ref.read(countriesProvider.future);
      final categoriesFuture  = _fetchCategories(session);

      final accountsRes = await accountsFuture;
      final groupRes    = await groupFuture;
      final currencies  = await currenciesFuture;
      final countries   = await countriesFuture;
      final categories  = await categoriesFuture;

      if (mounted) {
        final groups = List<Map<String, dynamic>>.from(groupRes.data as List);
        setState(() {
          _customers       = List<Map<String, dynamic>>.from(accountsRes.data as List);
          _groups          = groups;
          _categories      = categories;
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

  // Two-step common-masters lookup (type_key -> type_id -> masters), same
  // pattern as SalesOrderRemoteDs.getIncoterms() (086).
  Future<List<Map<String, dynamic>>> _fetchCategories(UserSession session) async {
    final typeRes = await DioClient.instance.get('/rim_common_master_types', queryParameters: {
      'type_key': 'eq.CUSTOMER_CATEGORY',
      'select':   'id',
      'limit':    '1',
    });
    final typeList = typeRes.data as List;
    if (typeList.isEmpty) return [];
    final typeId = (typeList.first as Map<String, dynamic>)['id'] as String;
    final res = await DioClient.instance.get('/rim_common_masters', queryParameters: {
      'type_id':    'eq.$typeId',
      'client_id':  'eq.${session.clientId}',
      'company_id': 'eq.${session.companyId}',
      'is_deleted': 'eq.false',
      'is_active':  'eq.true',
      'select':     'id,description',
      'order':      'sort_order.asc,description.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  String _groupDisplayFor(String? id) {
    if (id == null) return '';
    final g = _groups.firstWhere((g) => g['id'] == id, orElse: () => const {});
    if (g.isEmpty) return '';
    return '[${g['account_code']}] ${g['account_name']}';
  }

  // PostgREST returns Content-Range: 0-24/342 with Prefer: count=exact
  int? _parseTotal(Response res) {
    final raw = res.headers.value('content-range');
    if (raw == null) return null;
    return int.tryParse(raw.split('/').last.trim());
  }

  // rim_cities keys off country_code (TEXT), not a country_id FK -- resolve
  // it from the already-loaded _countries list. This was the actual root
  // cause of "city is not selectable": the old query filtered on a
  // country_id column that doesn't exist on rim_cities at all, so every
  // request 400'd and was silently swallowed by the catch block below,
  // leaving _cities permanently empty. Nothing to do with a missing
  // state/province level.
  String? get _selectedCountryCode {
    final c = _countries.firstWhere((c) => c['id'] == _countryId, orElse: () => const {});
    return c['country_code'] as String?;
  }

  // Same 3-level cascade as lib/features/setup/presentation/screens/
  // cities_screen.dart (Country -> Division -> City), reusing the
  // already-seeded rim_divisions state/province master (009_divisions.sql)
  // that was never surfaced in this screen before.
  Future<void> _loadDivisions() async {
    final countryCode = _selectedCountryCode;
    if (countryCode == null) { setState(() => _divisions = []); return; }
    final session = ref.read(sessionProvider)!;
    try {
      final res = await DioClient.instance.get('/rim_divisions', queryParameters: {
        'country_code': 'eq.$countryCode',
        'or': '(is_system.eq.true,and(client_id.eq.${session.clientId},company_id.eq.${session.companyId}))',
        'select': 'id,division_name',
        'order':  'division_name.asc',
      });
      if (mounted) setState(() => _divisions = List<Map<String, dynamic>>.from(res.data as List));
    } on DioException { /* silent */ }
  }

  Future<void> _loadCities() async {
    final countryCode = _selectedCountryCode;
    if (countryCode == null) { setState(() => _cities = []); return; }
    final session = ref.read(sessionProvider)!;
    try {
      final params = <String, dynamic>{
        'client_id':    'eq.${session.clientId}',
        'company_id':   'eq.${session.companyId}',
        'country_code': 'eq.$countryCode',
        'is_deleted':   'eq.false',
        'select':       'id,city_name,division_id',
        'order':        'city_name.asc',
      };
      if (_divisionId != null) params['division_id'] = 'eq.$_divisionId';
      final res = await DioClient.instance.get('/rim_cities', queryParameters: params);
      if (mounted) setState(() => _cities = List<Map<String, dynamic>>.from(res.data as List));
    } on DioException { /* silent */ }
  }

  void _onCountryChanged(String? v) {
    setState(() { _countryId = v; _divisionId = null; _cityId = null; _divisions = []; _cities = []; });
    if (v != null) { _loadDivisions(); _loadCities(); }
  }

  void _onDivisionChanged(String? v) {
    setState(() { _divisionId = v; _cityId = null; });
    _loadCities();
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
              (c['email'] as String? ?? '').toLowerCase().contains(q) ||
              (c['contact_person'] as String? ?? '').toLowerCase().contains(q),
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
      _category         = row['party_category'] as String?;
      _limitCtrl.text   = row['credit_limit'] != null
          ? row['credit_limit'].toString() : '';
      _daysCtrl.text    = (row['credit_days'] ?? 30).toString();
      _partyType        = row['party_type']  as String?;
      _currencyId       = row['account_currency_id'] as String?;
      _countryId        = row['country_id']  as String?;
      _divisionId       = null;
      _cityId           = row['city_id']     as String?;
      _creditBlocked    = row['is_credit_blocked'] as bool? ?? false;
      _isActive         = row['is_active'] as bool? ?? true;
      _customerGroupId  = row['parent_id'] as String?;
      _groupDisplay     = _groupDisplayFor(_customerGroupId);
      _divisions        = [];
      _cities           = [];
      _hasTransactions  = null; // unknown until the check below resolves
    });
    if (_countryId != null) {
      _loadDivisions();
      // Cities load unfiltered by division first (division_id is unknown
      // until we see which city was already picked) -- once loaded, back-
      // fill the Division dropdown from the selected city's own
      // division_id purely for display; the City list itself stays as-is.
      _loadCities().then((_) {
        if (!mounted || _cityId == null) return;
        final city = _cities.firstWhere((c) => c['id'] == _cityId, orElse: () => const {});
        final divId = city['division_id'] as String?;
        if (divId != null) setState(() => _divisionId = divId);
      });
    }
    _checkHasTransactions(row['id'] as String);
  }

  Future<void> _checkHasTransactions(String accountId) async {
    final result = await accountHasTransactions(accountId);
    if (mounted) setState(() => _hasTransactions = result);
  }

  void _clearForm() {
    for (final c in [_nameCtrl, _contactCtrl, _phoneCtrl, _emailCtrl,
        _addr1Ctrl, _addr2Ctrl, _taxIdCtrl, _limitCtrl, _daysCtrl]) {
      c.clear();
    }
    _partyType = null; _currencyId = null;
    _countryId = null; _divisionId = null; _cityId = null;
    _category  = null;
    _creditBlocked = false; _isActive = true;
    _divisions = []; _cities = [];
    _hasTransactions = false; // a brand-new account never has transactions
    _customerGroupId = _groups.isEmpty ? null : _groups.first['id'] as String;
    _groupDisplay     = _groupDisplayFor(_customerGroupId);
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
        await DioClient.instance.post('/rim_accounts', data: _buildPayload(session, name, code: code));
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
      {String? code}) => {
    'parent_id':       _customerGroupId,
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
    'party_category':  _category,
    'credit_limit':    _limitCtrl.text.trim().isEmpty
        ? null : double.tryParse(_limitCtrl.text.trim()),
    'credit_days':     int.tryParse(_daysCtrl.text.trim()) ?? 30,
    'is_credit_blocked': _creditBlocked,
    'is_active':       _isActive,
    'client_id':       session.clientId,
    'company_id':      session.companyId,
    'updated_by':      session.userId,
    if (code != null) ...{
      'accounting_std': 'OHADA', // derived from seeded data
      'created_by':    session.userId,
    },
  };

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
        if (!offline && canAdd)
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
          style: SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider)),
          decoration: SakalFieldCard.bareDecoration.copyWith(
            hintText: 'Search name, code, phone, contact…',
            hintStyle: const TextStyle(fontSize: 12, color: AppColors.textDisabled, fontWeight: FontWeight.normal),
            prefixIcon: const Icon(Icons.search, size: 16),
          ),
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
                final isInactive = !(row['is_active'] as bool? ?? true);
                final groupName = _groupDisplayFor(row['parent_id'] as String?);
                final subtitle2 = [
                  groupName.isEmpty ? null : groupName,
                  row['contact_person'] as String?,
                ].where((s) => s != null && s.isNotEmpty).join(' · ');
                return InkWell(
                  onTap: () => _openEdit(row),
                  child: Container(
                    color: isSelected
                        ? ThemePresetConfig.all[ref.watch(themePresetProvider)]!.accent.withValues(alpha: 0.15)
                        : (isInactive ? const Color(0xFFF9FAFB) : null),
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
                          style: TextStyle(fontSize: 13,
                              color: isInactive ? AppColors.textDisabled : AppColors.primary,
                              fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(row['account_name'] as String,
                            style: TextStyle(fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: isInactive ? AppColors.textDisabled : AppColors.textPrimary)),
                        Text(
                          [
                            row['account_code'] as String?,
                            row['phone'] as String?,
                          ].where((s) => s != null && s.isNotEmpty)
                              .join(' · '),
                          style: const TextStyle(fontSize: 11,
                              color: AppColors.textSecondary),
                        ),
                        if (subtitle2.isNotEmpty)
                          Text(subtitle2,
                              style: const TextStyle(fontSize: 11,
                                  color: AppColors.textDisabled)),
                      ])),
                      if (isInactive)
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

  Widget _formTitleBlock(bool isAdd) => Text(
      isAdd ? 'New Customer' : 'Edit Customer',
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
          color: AppColors.textPrimary));

  Widget _formCloseButton() => IconButton(
      icon: const Icon(Icons.close, size: 18),
      onPressed: () => setState(() { _selected = null; _isAdd = false; }));

  Widget _formActionButtons(bool isAdd) =>
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (isAdd ? canAdd : canEdit)
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : Text(isAdd ? 'Create Customer' : 'Save Changes'),
          ),
      ]);

  Widget _formPanel() {
    final isAdd = _isAdd;
    final row   = _selected;
    final mobile = Responsive.isMobile(context);
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
                _formActionButtons(isAdd),
              ])
            : Row(children: [
                Expanded(child: _formTitleBlock(isAdd)),
                _formActionButtons(isAdd),
                const SizedBox(width: 8),
                _formCloseButton(),
              ]),
      ),
      const Divider(height: 1, color: AppColors.border),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Account code (read-only on edit, auto on add)
            if (!isAdd && row != null) ...[
              SakalFieldCard.readOnly(
                label: 'Account Code',
                value: row['account_code'] as String? ?? '',
              ),
              const SizedBox(height: 16),
            ],

            // Name
            SakalFieldCard(
              label: 'Customer Name',
              required: true,
              editable: true,
              child: TextField(
                controller: _nameCtrl,
                style: SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider)),
                decoration: SakalFieldCard.bareDecoration.copyWith(
                  hintText: 'Enter customer name',
                  hintStyle: const TextStyle(fontSize: 12, color: AppColors.textDisabled, fontWeight: FontWeight.normal),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Parent Group — nested Chart-of-Accounts group this customer
            // is created under. Previously hardcoded to whichever group
            // happened to load first; now user-selectable at any depth
            // (additional nested groups are created via Chart of Accounts,
            // not here). Editable in both Add and Edit — re-parenting an
            // existing customer is allowed.
            SakalFieldCard(
              label: 'Parent Group',
              editable: true,
              child: SakalAutocomplete<Map<String, dynamic>>(
                key: ValueKey(_customerGroupId),
                initialValue: TextEditingValue(text: _groupDisplay),
                displayStringForOption: (g) => '[${g['account_code']}] ${g['account_name']}',
                optionsBuilder: (v) {
                  final q = v.text.toLowerCase().trim();
                  if (q.isEmpty) return _groups;
                  return _groups.where((g) =>
                      (g['account_code'] as String).toLowerCase().contains(q) ||
                      (g['account_name'] as String).toLowerCase().contains(q));
                },
                onSelected: (g) => setState(() {
                  _customerGroupId = g['id'] as String;
                  _groupDisplay    = '[${g['account_code']}] ${g['account_name']}';
                }),
                decoration: SakalFieldCard.bareDecoration.copyWith(hintText: 'Select parent group…'),
                style: SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider)),
              ),
            ),
            const SizedBox(height: 16),

            // Currency — locked once this account has any posted GL
            // transaction (checked in _openEdit via accountHasTransactions),
            // since changing it after the fact would corrupt historical
            // multi-currency reporting. Never locked for a new (unsaved)
            // customer -- _hasTransactions is seeded false in _clearForm().
            SakalFieldCard(
              label: 'Ledger Currency',
              editable: _hasTransactions != true,
              child: DropdownButtonFormField<String>(
                initialValue: _currencyId,
                isExpanded: true, isDense: true, itemHeight: null,
                style: SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider)),
                decoration: SakalFieldCard.bareDecoration.copyWith(
                  hintText: 'Select…',
                  hintStyle: const TextStyle(fontSize: 12, color: AppColors.textDisabled, fontWeight: FontWeight.normal),
                ),
                items: _currencies.map((c) => DropdownMenuItem(
                  value: c['id'] as String,
                  child: Text('${c['currency_id']} — ${c['currency_name']}',
                      overflow: TextOverflow.ellipsis),
                )).toList(),
                onChanged: _hasTransactions == true ? null : (v) => setState(() => _currencyId = v),
              ),
            ),
            if (_hasTransactions == true) ...[
              const SizedBox(height: 4),
              const Text('Locked — this account already has posted transactions.',
                  style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            ],
            const SizedBox(height: 20),

            // Active — replaces the old Delete action entirely (no
            // transaction-existence check needed, since this is always
            // freely reversible in both directions). Inactive only affects
            // eligibility as a NEW-transaction picker option (accountsProvider
            // already filters is_active=true app-wide) -- it never hides
            // the account from this list or from any report/ledger.
            if (!isAdd) ...[
              SwitchListTile.adaptive(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Active',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                subtitle: const Text(
                    'Inactive accounts cannot be picked for new transactions, but stay visible here and in reports',
                    style: TextStyle(fontSize: 11)),
                value: _isActive,
                activeThumbColor: AppColors.positive,
                onChanged: (v) => setState(() => _isActive = v),
              ),
              const SizedBox(height: 12),
            ],

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
          ]),
        ),
      ),
    ]);
  }

  List<Widget> _partyFields() {
    final mobile = Responsive.isMobile(context);
    final isCompact = ref.watch(isCompactDensityProvider);
    final fieldStyle = SakalFieldCard.valueTextStyle(isCompact);
    InputDecoration bare({String? hint}) => hint == null
        ? SakalFieldCard.bareDecoration
        : SakalFieldCard.bareDecoration.copyWith(
            hintText: hint,
            hintStyle: const TextStyle(fontSize: 12, color: AppColors.textDisabled, fontWeight: FontWeight.normal),
          );

    return [
      // Party Type
      SakalFieldCard(
        label: 'Party Type',
        editable: true,
        child: DropdownButtonFormField<String>(
          initialValue: _partyType,
          isExpanded: true, isDense: true, itemHeight: null,
          style: fieldStyle,
          decoration: bare(hint: 'Select…'),
          items: _partyTypes.map((t) => DropdownMenuItem(
              value: t, child: Text(t))).toList(),
          onChanged: (v) => setState(() => _partyType = v),
        ),
      ),
      const SizedBox(height: 14),

      // Contact + Phone
      SakalFieldRow(isMobile: mobile, children: [
        SakalFieldCard(
          label: 'Contact Person',
          editable: true,
          child: TextField(controller: _contactCtrl, style: fieldStyle, decoration: bare()),
        ),
        SakalFieldCard(
          label: 'Phone',
          editable: true,
          child: TextField(controller: _phoneCtrl, style: fieldStyle, decoration: bare()),
        ),
      ]),
      const SizedBox(height: 14),

      SakalFieldCard(
        label: 'Email',
        editable: true,
        child: TextField(controller: _emailCtrl, style: fieldStyle, decoration: bare()),
      ),
      const SizedBox(height: 14),

      SakalFieldCard(
        label: 'Address Line 1',
        editable: true,
        child: TextField(controller: _addr1Ctrl, style: fieldStyle, decoration: bare()),
      ),
      const SizedBox(height: 10),
      SakalFieldCard(
        label: 'Address Line 2',
        editable: true,
        child: TextField(controller: _addr2Ctrl, style: fieldStyle, decoration: bare()),
      ),
      const SizedBox(height: 14),

      // Country + Division (State/Province) + City -- Division narrows the
      // City list but is not itself stored on rim_accounts; the picked
      // City already carries its own division_id via FK.
      SakalFieldRow(isMobile: mobile, children: [
        SakalFieldCard(
          label: 'Country',
          editable: true,
          child: DropdownButtonFormField<String>(
            initialValue: _countryId,
            isExpanded: true, isDense: true, itemHeight: null,
            style: fieldStyle,
            decoration: bare(hint: 'Select…'),
            items: _countries.map((c) => DropdownMenuItem(
                value: c['id'] as String,
                child: Text(c['country_name'] as String,
                    overflow: TextOverflow.ellipsis))).toList(),
            onChanged: _onCountryChanged,
          ),
        ),
        SakalFieldCard(
          label: 'State / Province',
          editable: true,
          child: DropdownButtonFormField<String>(
            initialValue: _divisionId,
            isExpanded: true, isDense: true, itemHeight: null,
            style: fieldStyle,
            decoration: bare(hint: _countryId == null ? 'Select country first' : 'All'),
            items: _divisions.map((d) => DropdownMenuItem(
                value: d['id'] as String,
                child: Text(d['division_name'] as String,
                    overflow: TextOverflow.ellipsis))).toList(),
            onChanged: _countryId == null ? null : _onDivisionChanged,
          ),
        ),
        SakalFieldCard(
          label: 'City',
          editable: true,
          child: DropdownButtonFormField<String>(
            initialValue: _cityId,
            isExpanded: true, isDense: true, itemHeight: null,
            style: fieldStyle,
            decoration: bare(hint: 'Select…'),
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
        label: 'Tax ID (TVA / TIN / GSTIN)',
        editable: true,
        child: TextField(controller: _taxIdCtrl, style: fieldStyle, decoration: bare()),
      ),
      const SizedBox(height: 14),

      // Category + Credit Days + Credit Limit
      SakalFieldRow(isMobile: mobile, children: [
        SakalFieldCard(
          label: 'Category',
          editable: true,
          child: DropdownButtonFormField<String>(
            initialValue: _category,
            isExpanded: true, isDense: true, itemHeight: null,
            style: fieldStyle,
            decoration: bare(hint: 'Select…'),
            items: _categories.map((c) => DropdownMenuItem(
                value: c['description'] as String,
                child: Text(c['description'] as String,
                    overflow: TextOverflow.ellipsis))).toList(),
            onChanged: (v) => setState(() => _category = v),
          ),
        ),
        SakalFieldCard(
          label: 'Credit Days',
          editable: true,
          numeric: true,
          child: TextField(
              controller: _daysCtrl,
              textAlign: TextAlign.right,
              keyboardType: TextInputType.number,
              style: fieldStyle,
              decoration: bare()),
        ),
        SakalFieldCard(
          label: 'Credit Limit',
          editable: true,
          numeric: true,
          child: SakalFormattedNumberField(
              controller: _limitCtrl,
              textAlign: TextAlign.right,
              numberFormatStyle: ref.watch(sessionProvider)?.numberFormat ?? 'INTERNATIONAL',
              style: fieldStyle,
              decoration: bare(hint: '0.00')),
        ),
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

extension _NullIfEmpty on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
