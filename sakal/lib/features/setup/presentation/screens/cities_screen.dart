import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/database/datasources/generic_lookup_local_ds.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/sakal_adaptive_list.dart';

class CitiesScreen extends ConsumerStatefulWidget {
  const CitiesScreen({super.key});

  @override
  ConsumerState<CitiesScreen> createState() => _CitiesScreenState();
}

class _CitiesScreenState extends ConsumerState<CitiesScreen> {
  List<Map<String, dynamic>> _countries  = [];
  List<Map<String, dynamic>> _divisions  = [];
  List<Map<String, dynamic>> _cities     = [];

  String? _selectedCountry;
  String? _selectedDivision;  // division id (uuid)
  final _searchCtrl = TextEditingController();

  bool _loadingCountries  = true;
  bool _loadingDivisions  = false;
  bool _loadingCities     = false;
  String? _error;

  final Set<String> _toggling = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCountries());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── Loaders ───────────────────────────────────────────────────────

  Future<void> _loadCountries() async {
    if (!mounted) return;
    final session = ref.read(sessionProvider)!;
    setState(() { _loadingCountries = true; _error = null; });
    try {
      List<Map<String, dynamic>> rows;
      if (session.offlineMode && !kIsWeb) {
        final local = GenericLookupLocalDs(ref.read(appDatabaseProvider));
        rows = await local.getLookups(
          cacheKey: 'COUNTRIES', clientId: session.clientId, companyId: session.companyId,
        );
      } else {
        final res = await DioClient.instance.get('/rim_countries', queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false',
          'order':      'country_name.asc',
          'select':     'id,country_code,country_name',
        });
        rows = (res.data as List).cast<Map<String, dynamic>>();
        if (!kIsWeb) {
          final local = GenericLookupLocalDs(ref.read(appDatabaseProvider));
          unawaited(local.upsertLookups(
            cacheKey: 'COUNTRIES', rows: rows, idOf: (r) => r['id'] as String,
            labelOf: (r) => r['country_name'] as String? ?? '',
            clientId: session.clientId, companyId: session.companyId,
          ));
        }
      }
      if (mounted) { setState(() {
        _countries = rows;
        _loadingCountries = false;
      }); }
    } on DioException catch (e) {
      if (mounted) { setState(() {
        _error = e.response?.data?['message'] as String? ?? 'Failed to load countries';
        _loadingCountries = false;
      }); }
    }
  }

  Future<void> _loadDivisions() async {
    if (_selectedCountry == null || !mounted) return;
    final session = ref.read(sessionProvider)!;
    setState(() { _loadingDivisions = true; _divisions = []; _selectedDivision = null; });
    try {
      List<Map<String, dynamic>> rows;
      if (session.offlineMode && !kIsWeb) {
        final local = GenericLookupLocalDs(ref.read(appDatabaseProvider));
        rows = await local.getLookups(
          cacheKey: 'DIVISIONS', clientId: session.clientId, companyId: session.companyId,
          parentId: _selectedCountry,
        );
      } else {
        final res = await DioClient.instance.get('/rim_divisions', queryParameters: {
          'country_code': 'eq.$_selectedCountry',
          'or': '(is_system.eq.true,and(client_id.eq.${session.clientId},company_id.eq.${session.companyId}))',
          'order': 'division_name.asc',
          'select': 'id,division_name,division_type,country_code',
        });
        rows = (res.data as List).cast<Map<String, dynamic>>();
        if (!kIsWeb) {
          final local = GenericLookupLocalDs(ref.read(appDatabaseProvider));
          unawaited(local.upsertLookups(
            cacheKey: 'DIVISIONS', rows: rows, idOf: (r) => r['id'] as String,
            labelOf: (r) => r['division_name'] as String? ?? '',
            parentIdOf: (r) => r['country_code'] as String? ?? '',
            clientId: session.clientId, companyId: session.companyId,
          ));
        }
      }
      if (mounted) { setState(() {
        _divisions = rows;
        _loadingDivisions = false;
      }); }
    } on DioException {
      if (mounted) { setState(() => _loadingDivisions = false); }
    }
  }

  Future<void> _loadCities() async {
    if (_selectedCountry == null || !mounted) return;
    final session = ref.read(sessionProvider)!;
    setState(() { _loadingCities = true; _error = null; });
    try {
      List<Map<String, dynamic>> rows;
      if (session.offlineMode && !kIsWeb) {
        final local = GenericLookupLocalDs(ref.read(appDatabaseProvider));
        rows = await local.getLookups(
          cacheKey: 'CITIES', clientId: session.clientId, companyId: session.companyId,
          parentId: _selectedCountry,
        );
        if (_selectedDivision != null) {
          rows = rows.where((c) => c['division_id'] == _selectedDivision).toList();
        }
      } else {
        final params = <String, dynamic>{
          'client_id':    'eq.${session.clientId}',
          'company_id':   'eq.${session.companyId}',
          'country_code': 'eq.$_selectedCountry',
          'is_deleted':   'eq.false',
          'order':        'city_name.asc',
          'select':       'id,city_name,division_id,is_active,country_code',
        };
        if (_selectedDivision != null) {
          params['division_id'] = 'eq.$_selectedDivision';
        }
        final res = await DioClient.instance.get('/rim_cities', queryParameters: params);
        rows = (res.data as List).cast<Map<String, dynamic>>();
        if (!kIsWeb) {
          final local = GenericLookupLocalDs(ref.read(appDatabaseProvider));
          unawaited(local.upsertLookups(
            cacheKey: 'CITIES', rows: rows, idOf: (r) => r['id'] as String,
            labelOf: (r) => r['city_name'] as String? ?? '',
            parentIdOf: (r) => r['country_code'] as String? ?? '',
            clientId: session.clientId, companyId: session.companyId,
          ));
        }
      }
      if (mounted) { setState(() {
        _cities = rows;
        _loadingCities = false;
      }); }
    } on DioException catch (e) {
      if (mounted) { setState(() {
        _error = e.response?.data?['message'] as String? ?? 'Failed to load cities';
        _loadingCities = false;
      }); }
    }
  }

  // ── Actions ───────────────────────────────────────────────────────

  Future<void> _save(Map<String, dynamic> data, String? id) async {
    final session = ref.read(sessionProvider)!;
    try {
      if (id == null) {
        await DioClient.instance.post('/rim_cities', data: {
          ...data,
          'client_id':  session.clientId,
          'company_id': session.companyId,
        });
      } else {
        await DioClient.instance.patch(
          '/rim_cities',
          queryParameters: {'id': 'eq.$id'},
          data: data,
        );
      }
      _loadCities();
    } on DioException catch (e) {
      final msg = e.response?.data?['message'] as String? ?? 'Save failed';
      if (mounted) { ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: AppColors.negative),
      ); }
    }
  }

  Future<void> _toggleActive(String id, bool current) async {
    if (_toggling.contains(id)) return;
    setState(() {
      _toggling.add(id);
      final idx = _cities.indexWhere((c) => c['id'] == id);
      if (idx >= 0) _cities[idx] = {..._cities[idx], 'is_active': !current};
    });
    try {
      await DioClient.instance.patch(
        '/rim_cities',
        queryParameters: {'id': 'eq.$id'},
        data: {'is_active': !current},
      );
    } on DioException {
      // revert
      setState(() {
        final idx = _cities.indexWhere((c) => c['id'] == id);
        if (idx >= 0) _cities[idx] = {..._cities[idx], 'is_active': current};
      });
    } finally {
      if (mounted) setState(() => _toggling.remove(id));
    }
  }

  Future<void> _delete(String id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete City'),
        content: const Text('Remove this city? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.negative),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await DioClient.instance.patch(
        '/rim_cities',
        queryParameters: {'id': 'eq.$id'},
        data: {'is_deleted': true},
      );
      _loadCities();
    } on DioException catch (e) {
      final msg = e.response?.data?['message'] as String? ?? 'Delete failed';
      if (mounted) { ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: AppColors.negative),
      ); }
    }
  }

  void _openDialog([Map<String, dynamic>? entry]) {
    final offline = ref.read(sessionProvider)?.offlineMode ?? false;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CityDialog(
        countries:          _countries,
        divisions:          _divisions,
        entry:              entry,
        preselectedCountry: _selectedCountry,
        preselectedDivision: _selectedDivision,
        offline:            offline,
        onSave: (data, id) async => _save(data, id),
      ),
    );
  }

  // ── Filtered list ─────────────────────────────────────────────────

  List<Map<String, dynamic>> get _filtered {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return _cities;
    return _cities.where((c) {
      return (c['city_name'] as String? ?? '').toLowerCase().contains(q);
    }).toList();
  }

  String _divisionName(String? divId) {
    if (divId == null) return '—';
    final d = _divisions.firstWhere(
      (d) => d['id'] == divId,
      orElse: () => {'division_name': '—'},
    );
    return d['division_name'] as String? ?? '—';
  }

  @override
  Widget build(BuildContext context) {
    final offline = ref.watch(sessionProvider)?.offlineMode ?? false;
    final filtered = _filtered;
    final activeCount = _cities.where((c) => c['is_active'] == true).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
          child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ────────────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Cities',
                        style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary)),
                    const SizedBox(height: 4),
                    Text(
                      _selectedCountry == null
                          ? 'Select a country to view its cities'
                          : '$activeCount of ${_cities.length} active',
                      style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              if (_selectedCountry != null && !offline)
                ElevatedButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add City'),
                  onPressed: () => _openDialog(),
                ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Filters ───────────────────────────────────────────────
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              // Country
              SizedBox(
                width: 280,
                child: _loadingCountries
                    ? const LinearProgressIndicator()
                    : DropdownButtonFormField<String>(
                        initialValue: _selectedCountry,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Country',
                          prefixIcon: Icon(Icons.public_outlined),
                          isDense: true,
                        ),
                        hint: const Text('Select country…'),
                        items: _countries.map((c) => DropdownMenuItem(
                          value: c['country_code'] as String,
                          child: Text(c['country_name'] as String),
                        )).toList(),
                        onChanged: (v) {
                          setState(() {
                            _selectedCountry = v;
                            _selectedDivision = null;
                            _divisions = [];
                            _cities = [];
                          });
                          _loadDivisions();
                          _loadCities();
                        },
                      ),
              ),

              // Division filter
              if (_selectedCountry != null)
                SizedBox(
                  width: 240,
                  child: _loadingDivisions
                      ? const LinearProgressIndicator()
                      : DropdownButtonFormField<String>(
                          initialValue: _selectedDivision,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Division (optional)',
                            prefixIcon: Icon(Icons.layers_outlined),
                            isDense: true,
                          ),
                          hint: const Text('All divisions'),
                          items: [
                            const DropdownMenuItem<String>(
                              value: null,
                              child: Text('All divisions'),
                            ),
                            ..._divisions.map((d) => DropdownMenuItem(
                              value: d['id'] as String,
                              child: Text(d['division_name'] as String),
                            )),
                          ],
                          onChanged: (v) {
                            setState(() => _selectedDivision = v);
                            _loadCities();
                          },
                        ),
                ),

              // Search
              if (_selectedCountry != null)
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Search city',
                      prefixIcon: Icon(Icons.search),
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),

          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(_error!,
                  style: const TextStyle(color: AppColors.negative, fontSize: 13)),
            ),
        ],
          ),
        ),
        const SizedBox(height: 4),

        // ── List — SakalAdaptiveList owns loading/error/empty +
        // mobile-card/desktop-table switch; the raw horizontal-scroll-only
        // table here was hard to use on mobile (Edit/Delete scrolled off
        // screen with no visible scrollbar hint).
        Expanded(
          child: _selectedCountry == null
              ? Center(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 48),
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.border),
                      borderRadius: BorderRadius.circular(8),
                      color: Colors.white,
                    ),
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.location_city_outlined, size: 40, color: AppColors.textDisabled),
                        SizedBox(height: 12),
                        Text('Select a country above to view its cities',
                            style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                      ],
                    ),
                  ),
                )
              : SakalAdaptiveList<Map<String, dynamic>>(
                  loading: _loadingCities,
                  error: null,
                  rows: filtered,
                  columns: const [
                    SakalListColumn('City Name', flex: 3),
                    SakalListColumn('Division', flex: 3),
                    SakalListColumn('Active', flex: 1),
                    SakalListColumn('Actions', flex: 2),
                  ],
                  rowBuilder: (c, i) => _buildTableRow(c, offline),
                  cardBuilder: (c) => _CityCard(
                    row: c,
                    divisionName: _divisionName(c['division_id'] as String?),
                    offline: offline,
                    toggling: _toggling.contains(c['id'] as String?),
                    onToggle: () => _toggleActive(c['id'] as String, c['is_active'] as bool? ?? true),
                    onEdit: () => _openDialog(c),
                    onDelete: () => _delete(c['id'] as String),
                  ),
                  emptyState: const Center(
                    child: Text('No cities found. Add one using the button above.',
                        style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                        textAlign: TextAlign.center),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildTableRow(Map<String, dynamic> c, bool offline) {
    final active = c['is_active'] as bool? ?? true;
    final id     = c['id'] as String;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 3,
            child: Text(c['city_name'] as String? ?? '',
                style: TextStyle(fontSize: 13,
                    color: active ? AppColors.textPrimary : AppColors.textDisabled)),
          ),
          Expanded(
            flex: 3,
            child: Text(_divisionName(c['division_id'] as String?),
                style: TextStyle(fontSize: 12,
                    color: active ? AppColors.textSecondary : AppColors.textDisabled)),
          ),
          Expanded(
            flex: 1,
            child: offline
                ? Icon(
                    active ? Icons.check_circle : Icons.cancel,
                    size: 18,
                    color: active ? AppColors.positive : AppColors.textDisabled,
                  )
                : Switch.adaptive(
                    value: active,
                    activeThumbColor: AppColors.positive,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: _toggling.contains(id) ? null : (_) => _toggleActive(id, active),
                  ),
          ),
          Expanded(
            flex: 2,
            child: offline
                ? const SizedBox()
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 17),
                        color: AppColors.primary,
                        tooltip: 'Edit',
                        onPressed: () => _openDialog(c),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 17),
                        color: AppColors.negative,
                        tooltip: 'Delete',
                        onPressed: () => _delete(id),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

// ── Mobile card ───────────────────────────────────────────────────────────────

class _CityCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final String divisionName;
  final bool offline;
  final bool toggling;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _CityCard({
    required this.row,
    required this.divisionName,
    required this.offline,
    required this.toggling,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final active = row['is_active'] as bool? ?? true;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(row['city_name'] as String? ?? '',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: active ? AppColors.textPrimary : AppColors.textDisabled)),
                      if (divisionName != '—')
                        Text(divisionName,
                            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                    ],
                  ),
                ),
                toggling
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : offline
                        ? Icon(
                            active ? Icons.check_circle : Icons.cancel,
                            size: 18,
                            color: active ? AppColors.positive : AppColors.textDisabled,
                          )
                        : Switch(
                            value: active,
                            onChanged: (_) => onToggle(),
                            activeThumbColor: AppColors.positive,
                          ),
              ],
            ),
            if (!offline) ...[
              const Divider(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: 'Edit',
                    icon: const Icon(Icons.edit_outlined, size: 18, color: AppColors.primary),
                    onPressed: onEdit,
                  ),
                  IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.negative),
                    onPressed: onDelete,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// Add / Edit City Dialog
// ══════════════════════════════════════════════════════════════════════

class _CityDialog extends StatefulWidget {
  final List<Map<String, dynamic>> countries;
  final List<Map<String, dynamic>> divisions;
  final Map<String, dynamic>? entry;
  final String? preselectedCountry;
  final String? preselectedDivision;
  final bool offline;
  final Future<void> Function(Map<String, dynamic> data, String? id) onSave;

  const _CityDialog({
    required this.countries,
    required this.divisions,
    required this.entry,
    required this.preselectedCountry,
    required this.preselectedDivision,
    required this.offline,
    required this.onSave,
  });

  @override
  State<_CityDialog> createState() => _CityDialogState();
}

class _CityDialogState extends State<_CityDialog> {
  final _formKey = GlobalKey<FormState>();
  late String? _countryCode;
  late String? _divisionId;
  late final TextEditingController _name;
  late bool _isActive;
  bool _saving = false;

  bool get _isEdit => widget.entry != null;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _countryCode = e?['country_code'] as String? ?? widget.preselectedCountry;
    _divisionId  = e?['division_id']  as String? ?? widget.preselectedDivision;
    _name        = TextEditingController(text: e?['city_name'] as String? ?? '');
    _isActive    = e?['is_active'] as bool? ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final data = <String, dynamic>{
      'country_code': _countryCode,
      'division_id':  _divisionId,
      'city_name':    _name.text.trim(),
      'is_active':    _isActive,
    };

    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    await widget.onSave(data, widget.entry?['id'] as String?);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Title
            Container(
              padding: const EdgeInsets.fromLTRB(24, 18, 12, 18),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppColors.border)),
              ),
              child: Row(
                children: [
                  Text(_isEdit ? 'Edit City' : 'Add City',
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                  ),
                ],
              ),
            ),

            // Form
            Padding(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Country
                    DropdownButtonFormField<String>(
                      initialValue: _countryCode,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Country *',
                        prefixIcon: Icon(Icons.public_outlined),
                      ),
                      hint: const Text('Select country'),
                      items: widget.countries.map((c) => DropdownMenuItem(
                        value: c['country_code'] as String,
                        child: Text(c['country_name'] as String),
                      )).toList(),
                      onChanged: _isEdit
                          ? null
                          : (v) => setState(() { _countryCode = v; _divisionId = null; }),
                      validator: (_) => _countryCode == null ? 'Required' : null,
                    ),
                    const SizedBox(height: 14),

                    // Division (optional)
                    DropdownButtonFormField<String>(
                      initialValue: _divisionId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Division (optional)',
                        prefixIcon: Icon(Icons.layers_outlined),
                      ),
                      hint: const Text('No division'),
                      items: [
                        const DropdownMenuItem<String>(
                          value: null,
                          child: Text('— No division —'),
                        ),
                        ...widget.divisions.map((d) => DropdownMenuItem(
                          value: d['id'] as String,
                          child: Text(d['division_name'] as String),
                        )),
                      ],
                      onChanged: (v) => setState(() => _divisionId = v),
                    ),
                    const SizedBox(height: 14),

                    // City name
                    TextFormField(
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'City Name *',
                        hintText: 'e.g. Kinshasa',
                        prefixIcon: Icon(Icons.location_city_outlined),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 14),

                    // Active switch
                    SwitchListTile.adaptive(
                      dense: true,
                      title: const Text('Active',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                      subtitle: const Text(
                          'Inactive cities are hidden from address autocomplete',
                          style: TextStyle(fontSize: 11)),
                      value: _isActive,
                      activeThumbColor: AppColors.positive,
                      onChanged: (v) => setState(() => _isActive = v),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const SizedBox(height: 16),

                    // Buttons
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 12),
                        ElevatedButton(
                          onPressed: (_saving || widget.offline) ? null : _submit,
                          child: _saving
                              ? const SizedBox(width: 18, height: 18,
                                  child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2))
                              : Text(_isEdit ? 'Save Changes' : 'Add City'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
