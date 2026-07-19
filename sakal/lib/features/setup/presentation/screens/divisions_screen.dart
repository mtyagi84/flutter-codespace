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

class DivisionsScreen extends ConsumerStatefulWidget {
  const DivisionsScreen({super.key});

  @override
  ConsumerState<DivisionsScreen> createState() => _DivisionsScreenState();
}

class _DivisionsScreenState extends ConsumerState<DivisionsScreen> {
  List<Map<String, dynamic>> _countries  = [];
  List<Map<String, dynamic>> _divisions  = [];
  String? _selectedCountry;
  bool _loadingCountries  = true;
  bool _loadingDivisions  = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCountries());
  }

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
      if (mounted) {
        setState(() {
          _countries = rows;
          _loadingCountries = false;
        });
      }
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
    setState(() { _loadingDivisions = true; _divisions = []; });
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
    } on DioException catch (e) {
      if (mounted) { setState(() {
        _error = e.response?.data?['message'] as String? ?? 'Failed to load divisions';
        _loadingDivisions = false;
      }); }
    }
  }

  Future<void> _save(Map<String, dynamic> data, String? id) async {
    final session = ref.read(sessionProvider)!;
    try {
      if (id == null) {
        await DioClient.instance.post('/rim_divisions', data: {
          ...data,
          'client_id':  session.clientId,
          'company_id': session.companyId,
          'is_system':  false,
        });
      } else {
        await DioClient.instance.patch(
          '/rim_divisions',
          queryParameters: {'id': 'eq.$id'},
          data: data,
        );
      }
      _loadDivisions();
    } on DioException catch (e) {
      final msg = e.response?.data?['message'] as String? ?? 'Save failed';
      if (mounted) { ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: AppColors.negative),
      ); }
    }
  }

  Future<void> _delete(String id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Division'),
        content: const Text('Remove this custom division? This cannot be undone.'),
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
      await DioClient.instance.delete('/rim_divisions', queryParameters: {'id': 'eq.$id'});
      _loadDivisions();
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
      builder: (_) => _DivisionDialog(
        countries:         _countries,
        entry:             entry,
        preselectedCountry: _selectedCountry,
        offline:           offline,
        onSave: (data, id) async => _save(data, id),
      ),
    );
  }

  // dominant division_type for the selected country (used as field label hint)
  String get _divisionLabel {
    if (_divisions.isEmpty) return 'Province / State';
    final counts = <String, int>{};
    for (final d in _divisions) {
      final t = d['division_type'] as String? ?? 'Province';
      counts[t] = (counts[t] ?? 0) + 1;
    }
    return counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  @override
  Widget build(BuildContext context) {
    final offline = ref.watch(sessionProvider)?.offlineMode ?? false;
    return Column(
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
                    const Text('Divisions',
                        style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary)),
                    const SizedBox(height: 4),
                    Text(
                      _selectedCountry == null
                          ? 'Select a country to view its divisions'
                          : '${_divisions.length} ${_divisionLabel.toLowerCase()}s'
                            '  ·  ${_divisions.where((d) => d['is_system'] != true).length} custom',
                      style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              if (_selectedCountry != null && !offline)
                ElevatedButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add Custom'),
                  onPressed: () => _openDialog(),
                ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Country filter ────────────────────────────────────────
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
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
                      setState(() { _selectedCountry = v; _divisions = []; });
                      _loadDivisions();
                    },
                  ),
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
        // mobile-card/desktop-table switch, replacing the raw fixed-width
        // table that never adapted for mobile.
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
                        Icon(Icons.map_outlined, size: 40, color: AppColors.textDisabled),
                        SizedBox(height: 12),
                        Text('Select a country above to view its divisions',
                            style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                      ],
                    ),
                  ),
                )
              : SakalAdaptiveList<Map<String, dynamic>>(
                  loading: _loadingDivisions,
                  error: null,
                  rows: _divisions,
                  columns: const [
                    SakalListColumn('Code', flex: 2),
                    SakalListColumn('Name', flex: 3),
                    SakalListColumn('Type', flex: 2),
                    SakalListColumn('Source', flex: 2),
                    SakalListColumn('Actions', flex: 2),
                  ],
                  rowBuilder: (d, i) => _buildTableRow(d, offline),
                  cardBuilder: (d) => _DivisionCard(
                    row: d,
                    offline: offline,
                    onEdit: () => _openDialog(d),
                    onDelete: () => _delete(d['id'] as String),
                  ),
                  emptyState: const Center(
                    child: Text('No divisions found. Add a custom one.',
                        style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                        textAlign: TextAlign.center),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildTableRow(Map<String, dynamic> d, bool offline) {
    final isSystem = d['is_system'] as bool? ?? true;
    final tc = isSystem ? AppColors.textSecondary : AppColors.textPrimary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 2,
            child: Text(d['division_code'] as String? ?? '',
                style: const TextStyle(fontSize: 12, color: AppColors.primary, fontFamily: 'monospace')),
          ),
          Expanded(
            flex: 3,
            child: Text(d['division_name'] as String? ?? '', style: TextStyle(fontSize: 13, color: tc)),
          ),
          Expanded(
            flex: 2,
            child: Text(d['division_type'] as String? ?? '',
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ),
          Expanded(flex: 2, child: _SourceBadge(isSystem: isSystem)),
          Expanded(
            flex: 2,
            child: (isSystem || offline)
                ? const SizedBox()
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 17),
                        color: AppColors.primary,
                        tooltip: 'Edit',
                        onPressed: () => _openDialog(d),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 17),
                        color: AppColors.negative,
                        tooltip: 'Delete',
                        onPressed: () => _delete(d['id'] as String),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

// ── Source badge ──────────────────────────────────────────────────────────────

class _SourceBadge extends StatelessWidget {
  final bool isSystem;
  const _SourceBadge({required this.isSystem});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: isSystem ? const Color(0xFFE8EAF6) : const Color(0xFFFFF8E1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          isSystem ? 'System' : 'Custom',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: isSystem ? const Color(0xFF3949AB) : AppColors.secondary,
          ),
        ),
      );
}

// ── Mobile card ───────────────────────────────────────────────────────────────

class _DivisionCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final bool offline;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _DivisionCard({
    required this.row,
    required this.offline,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isSystem = row['is_system'] as bool? ?? true;
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
                      Text(row['division_name'] as String? ?? '',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      Text(
                        '${row['division_code'] ?? ''} · ${row['division_type'] ?? ''}',
                        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                _SourceBadge(isSystem: isSystem),
              ],
            ),
            if (!isSystem && !offline) ...[
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
// Add / Edit Dialog
// ══════════════════════════════════════════════════════════════════════

class _DivisionDialog extends StatefulWidget {
  final List<Map<String, dynamic>> countries;
  final Map<String, dynamic>? entry;
  final String? preselectedCountry;
  final bool offline;
  final Future<void> Function(Map<String, dynamic> data, String? id) onSave;

  const _DivisionDialog({
    required this.countries,
    required this.entry,
    required this.preselectedCountry,
    required this.offline,
    required this.onSave,
  });

  @override
  State<_DivisionDialog> createState() => _DivisionDialogState();
}

class _DivisionDialogState extends State<_DivisionDialog> {
  final _formKey = GlobalKey<FormState>();
  late String? _countryCode;
  late final TextEditingController _code;
  late final TextEditingController _name;
  late String _type;
  bool _saving = false;

  static const _types = [
    'Province', 'State', 'Region', 'County',
    'Territory', 'Emirate', 'Bundesland', 'Union Territory', 'District', 'Other',
  ];

  bool get _isEdit => widget.entry != null;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _countryCode = e?['country_code'] as String? ?? widget.preselectedCountry;
    _code = TextEditingController(text: e?['division_code'] as String? ?? '');
    _name = TextEditingController(text: e?['division_name'] as String? ?? '');
    _type = e?['division_type'] as String? ?? 'Province';
  }

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final data = <String, dynamic>{
      'country_code':   _countryCode,
      'division_code':  _code.text.trim().toUpperCase(),
      'division_name':  _name.text.trim(),
      'division_type':  _type,
    };

    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    await widget.onSave(data, widget.entry?['id'] as String?);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
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
                  Text(_isEdit ? 'Edit Division' : 'Add Custom Division',
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
                      onChanged: _isEdit ? null : (v) => setState(() => _countryCode = v),
                      validator: (_) => _countryCode == null ? 'Required' : null,
                    ),
                    const SizedBox(height: 14),

                    // Division code + type
                    Row(children: [
                      Expanded(
                        child: TextFormField(
                          controller: _code,
                          enabled: !_isEdit,
                          textCapitalization: TextCapitalization.characters,
                          decoration: const InputDecoration(
                            labelText: 'Code *',
                            hintText: 'e.g. CD-LN',
                            helperText: 'Unique. Cannot change after creation.',
                          ),
                          validator: (v) =>
                              (v == null || v.trim().isEmpty) ? 'Required' : null,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _type,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'Type *'),
                          items: _types.map((t) => DropdownMenuItem(
                            value: t, child: Text(t),
                          )).toList(),
                          onChanged: (v) => setState(() => _type = v!),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 14),

                    // Division name
                    TextFormField(
                      controller: _name,
                      decoration: const InputDecoration(
                        labelText: 'Division Name *',
                        hintText: 'e.g. Lualaba Nord',
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 24),

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
                              : Text(_isEdit ? 'Save Changes' : 'Add Division'),
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
