import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';

const _locationTypes = ['Store', 'Warehouse', 'Office', 'Head Office', 'Distribution Centre'];

class LocationsScreen extends ConsumerStatefulWidget {
  const LocationsScreen({super.key});

  @override
  ConsumerState<LocationsScreen> createState() => _LocationsScreenState();
}

class _LocationsScreenState extends ConsumerState<LocationsScreen>
    with ScreenPermissionMixin<LocationsScreen> {
  @override String get screenName => '/setup/locations';

  List<Map<String, dynamic>> _rows   = [];
  List<Map<String, dynamic>> _groups = [];
  List<Map<String, dynamic>> _users  = [];
  List<Map<String, dynamic>> _cities = [];
  bool    _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        DioClient.instance.get(
          '/ric_locations',
          queryParameters: {
            'client_id':  'eq.${session.clientId}',
            'company_id': 'eq.${session.companyId}',
            'is_deleted': 'eq.false',
            'select':     '*,'
                'group:ric_location_groups!group_id(group_name),'
                'city:rim_cities!city_id(city_name)',
            'order':      'location_name.asc',
          },
        ),
        DioClient.instance.get('/ric_location_groups', queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false',
          'is_active':  'eq.true',
          'select':     'id,group_name',
          'order':      'group_name.asc',
        }),
        DioClient.instance.get('/rim_users', queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false',
          'select':     'id,full_name',
          'order':      'full_name.asc',
        }),
        DioClient.instance.get('/rim_cities', queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false',
          'select':     'id,city_name',
          'order':      'city_name.asc',
        }),
      ]);
      if (mounted) {
        setState(() {
          _rows    = List<Map<String, dynamic>>.from(results[0].data as List);
          _groups  = List<Map<String, dynamic>>.from(results[1].data as List);
          _users   = List<Map<String, dynamic>>.from(results[2].data as List);
          _cities  = List<Map<String, dynamic>>.from(results[3].data as List);
          _loading = false;
          _error   = null;
        });
      }
    } on DioException {
      if (mounted) setState(() { _loading = false; _error = 'Could not load locations.'; });
    }
  }

  Future<void> _toggleActive(Map<String, dynamic> row) async {
    final newVal = !(row['is_active'] as bool? ?? true);
    try {
      await DioClient.instance.patch(
        '/ric_locations',
        queryParameters: {'id': 'eq.${row['id']}'},
        data: {'is_active': newVal, 'updated_at': DateTime.now().toUtc().toIso8601String()},
        options: Options(headers: {'Prefer': 'return=minimal'}),
      );
      ref.invalidate(locationsProvider);
      _load();
    } on DioException {
      _showError('Could not update status.');
    }
  }

  Future<void> _delete(String id) async {
    try {
      await DioClient.instance.patch(
        '/ric_locations',
        queryParameters: {'id': 'eq.$id'},
        data: {'is_deleted': true, 'updated_at': DateTime.now().toUtc().toIso8601String()},
        options: Options(headers: {'Prefer': 'return=minimal'}),
      );
      ref.invalidate(locationsProvider);
      _load();
    } on DioException {
      _showError('Could not delete location.');
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppColors.negative),
    );
  }

  void _openDialog([Map<String, dynamic>? existing]) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _LocationDialog(
        existing: existing,
        groups: _groups,
        users: _users,
        cities: _cities,
        onSaved: _load,
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final offline = ref.watch(sessionProvider)?.offlineMode ?? false;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ────────────────────────────────────────────────
              Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Location Master',
                            style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary)),
                        SizedBox(height: 4),
                        Text('Manage stores, warehouses and offices under this company.',
                            style: TextStyle(
                                fontSize: 13, color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                  if (canAdd && !offline)
                    ElevatedButton.icon(
                      onPressed: () => _openDialog(),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add Location'),
                    ),
                ],
              ),
              const SizedBox(height: 24),

              if (offline) const OfflineBanner(),
              if (offline) const SizedBox(height: 16),

              // ── Error banner ──────────────────────────────────────────
              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.negative.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.negative.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline,
                          color: AppColors.negative, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                          child: Text(_error!,
                              style: const TextStyle(
                                  fontSize: 13, color: AppColors.negative))),
                      TextButton(
                          onPressed: _load,
                          child: const Text('Retry')),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],

              // ── Table ─────────────────────────────────────────────────
              Card(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(40),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : _rows.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(40),
                            child: Center(
                              child: Column(
                                children: [
                                  Icon(Icons.store_mall_directory_outlined,
                                      size: 40, color: AppColors.textSecondary),
                                  SizedBox(height: 12),
                                  Text('No locations yet.',
                                      style: TextStyle(
                                          color: AppColors.textSecondary)),
                                  Text('Click "Add Location" to create one.',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: AppColors.textSecondary)),
                                ],
                              ),
                            ),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _TableHeader(),
                              const Divider(height: 1),
                              ..._rows.asMap().entries.map((e) =>
                                  _TableRow(
                                    row: e.value,
                                    isEven: e.key.isEven,
                                    canEdit: canEdit && !offline,
                                    onEdit: () => _openDialog(e.value),
                                    onToggle: () => _toggleActive(e.value),
                                    onDelete: () => _confirmDelete(e.value['id'] as String),
                                  )),
                            ],
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Location?'),
        content: const Text(
            'This will mark the location as deleted. It will no longer appear in lists.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete',
                  style: TextStyle(color: AppColors.negative))),
        ],
      ),
    );
    if (ok == true) _delete(id);
  }
}

// ── Table header ──────────────────────────────────────────────────────────────

class _TableHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: const Row(
        children: [
          SizedBox(width: 200, child: _HCol('Location Name')),
          SizedBox(width: 90,  child: _HCol('Short')),
          SizedBox(width: 120, child: _HCol('Type')),
          SizedBox(width: 140, child: _HCol('Group')),
          SizedBox(width: 150, child: _HCol('Phone')),
          SizedBox(width: 80,  child: _HCol('Active')),
          SizedBox(width: 100, child: _HCol('Actions')),
        ],
      ),
    );
  }
}

class _HCol extends StatelessWidget {
  final String text;
  const _HCol(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppColors.textSecondary,
            letterSpacing: 0.3));
  }
}

// ── Table row ─────────────────────────────────────────────────────────────────

class _TableRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final bool isEven;
  final bool canEdit;
  final VoidCallback onEdit;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  const _TableRow({
    required this.row,
    required this.isEven,
    required this.canEdit,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final active = row['is_active'] as bool? ?? true;
    final group  = row['group'] as Map<String, dynamic>?;
    final city   = row['city']  as Map<String, dynamic>?;
    return Container(
      color: isEven ? Colors.transparent : AppColors.surfaceVariant.withValues(alpha: 0.35),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 200,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row['location_name'] ?? '',
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
                if ((row['address_line1'] ?? '').isNotEmpty || city != null)
                  Text(
                    [
                      if ((row['address_line1'] ?? '').isNotEmpty) row['address_line1'] as String,
                      if (city != null) city['city_name'] as String,
                    ].join(', '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textSecondary),
                  ),
              ],
            ),
          ),
          SizedBox(
            width: 90,
            child: Text(row['location_short'] ?? '—',
                style: const TextStyle(fontSize: 13, color: AppColors.textPrimary)),
          ),
          SizedBox(
            width: 120,
            child: _TypeChip(type: row['location_type'] as String?),
          ),
          SizedBox(
            width: 140,
            child: Text(group?['group_name'] as String? ?? '—',
                style: const TextStyle(fontSize: 13, color: AppColors.textPrimary),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          SizedBox(
            width: 150,
            child: Text(row['phone'] ?? '—',
                style: const TextStyle(fontSize: 13, color: AppColors.textPrimary)),
          ),
          SizedBox(
            width: 80,
            child: Switch(
              value: active,
              onChanged: canEdit ? (_) => onToggle() : null,
              activeThumbColor: AppColors.positive,
            ),
          ),
          SizedBox(
            width: 100,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined,
                      size: 18, color: AppColors.primary),
                  onPressed: canEdit ? onEdit : null,
                ),
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline,
                      size: 18, color: AppColors.negative),
                  onPressed: canEdit ? onDelete : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  final String? type;
  const _TypeChip({this.type});

  @override
  Widget build(BuildContext context) {
    if (type == null || type!.isEmpty) {
      return const Text('—',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary));
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(type!,
          style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.primary)),
    );
  }
}

// ── Add / Edit Dialog ─────────────────────────────────────────────────────────

class _LocationDialog extends ConsumerStatefulWidget {
  final Map<String, dynamic>? existing;
  final List<Map<String, dynamic>> groups;
  final List<Map<String, dynamic>> users;
  final List<Map<String, dynamic>> cities;
  final VoidCallback onSaved;
  const _LocationDialog({
    this.existing,
    required this.groups,
    required this.users,
    required this.cities,
    required this.onSaved,
  });

  @override
  ConsumerState<_LocationDialog> createState() => _LocationDialogState();
}

class _LocationDialogState extends ConsumerState<_LocationDialog> {
  final _formKey     = GlobalKey<FormState>();
  final _nameCtrl    = TextEditingController();
  final _shortCtrl   = TextEditingController();
  final _addr1Ctrl   = TextEditingController();
  final _addr2Ctrl   = TextEditingController();
  final _postalCtrl  = TextEditingController();
  final _phoneCtrl   = TextEditingController();
  final _emailCtrl   = TextEditingController();
  final _taxRegCtrl  = TextEditingController();
  final _serverCtrl  = TextEditingController();

  String? _locationType;
  String? _groupId;
  String? _responsibleUserId;
  String? _cityId;
  bool    _negativeStockAllowed = false;
  bool    _saving = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final d = widget.existing;
    if (d != null) {
      _nameCtrl.text   = d['location_name']  ?? '';
      _shortCtrl.text  = d['location_short'] ?? '';
      _addr1Ctrl.text  = d['address_line1']  ?? '';
      _addr2Ctrl.text  = d['address_line2']  ?? '';
      _postalCtrl.text = d['postal_code']    ?? '';
      _phoneCtrl.text  = d['phone']          ?? '';
      _emailCtrl.text  = d['email']          ?? '';
      _taxRegCtrl.text = d['tax_reg_number'] ?? '';
      _serverCtrl.text = d['server_url']     ?? '';
      _locationType    = d['location_type']  as String?;
      _groupId         = d['group_id']       as String?;
      _responsibleUserId = d['responsible_user_id'] as String?;
      _cityId          = d['city_id']        as String?;
      _negativeStockAllowed = d['is_negative_stock_allowed'] as bool? ?? false;
      if (_locationType != null && !_locationTypes.contains(_locationType)) {
        _locationType = null;
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _shortCtrl.dispose();
    _addr1Ctrl.dispose();
    _addr2Ctrl.dispose();
    _postalCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _taxRegCtrl.dispose();
    _serverCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all required fields.'), backgroundColor: Colors.orange),
      );
      return;
    }
    setState(() { _saving = true; _error = null; });
    final session = ref.read(sessionProvider)!;
    final now     = DateTime.now().toUtc().toIso8601String();

    final fields = {
      'location_name':             _nameCtrl.text.trim(),
      'location_short':            _shortCtrl.text.trim(),
      'location_type':             _locationType,
      'group_id':                  _groupId,
      'responsible_user_id':       _responsibleUserId,
      'address_line1':             _addr1Ctrl.text.trim(),
      'address_line2':             _addr2Ctrl.text.trim(),
      'city_id':                   _cityId,
      'postal_code':               _postalCtrl.text.trim(),
      'phone':                     _phoneCtrl.text.trim(),
      'email':                     _emailCtrl.text.trim(),
      'tax_reg_number':            _taxRegCtrl.text.trim(),
      'server_url':                _serverCtrl.text.trim(),
      'is_negative_stock_allowed': _negativeStockAllowed,
    };

    try {
      if (_isEdit) {
        await DioClient.instance.patch(
          '/ric_locations',
          queryParameters: {'id': 'eq.${widget.existing!['id']}'},
          data: {
            ...fields,
            'updated_at': now,
            'updated_by': session.userId,
          },
          options: Options(headers: {'Prefer': 'return=minimal'}),
        );
      } else {
        await DioClient.instance.post(
          '/ric_locations',
          data: {
            ...fields,
            'client_id':  session.clientId,
            'company_id': session.companyId,
            'is_active':  true,
            'is_deleted': false,
            'created_at': now,
            'created_by': session.userId,
          },
          options: Options(headers: {'Prefer': 'return=minimal'}),
        );
      }
      // locationsProvider (shared picker cache) is fetched once per app
      // session — invalidate so a new/edited location shows up elsewhere
      // (GRN, PO, User Location Access, ...) without a logout/login.
      ref.invalidate(locationsProvider);
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      widget.onSaved();
    } on DioException catch (e) {
      final msg = e.response?.data?['message'] as String? ?? 'Save failed. Please try again.';
      if (mounted) setState(() { _saving = false; _error = msg; });
    } catch (e) {
      if (mounted) setState(() { _saving = false; _error = 'Unexpected error: $e'; });
    }
  }

  static Widget _req(String text) => RichText(
        text: TextSpan(
          text: text,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 14, fontWeight: FontWeight.w400),
          children: const [
            TextSpan(text: ' *', style: TextStyle(color: AppColors.negative, fontWeight: FontWeight.w600)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Dialog header ──────────────────────────────────────
                  Row(
                    children: [
                      Icon(_isEdit ? Icons.edit_outlined : Icons.add_business_outlined,
                          color: AppColors.primary, size: 22),
                      const SizedBox(width: 10),
                      Text(_isEdit ? 'Edit Location' : 'Add Location',
                          style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary)),
                      const Spacer(),
                      IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(context, rootNavigator: true).pop()),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // ── Error ──────────────────────────────────────────────
                  if (_error != null) ...[
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.negative.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(_error!,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.negative)),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // ── Fields ─────────────────────────────────────────────
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextFormField(
                          controller: _nameCtrl,
                          decoration: InputDecoration(
                            label: _req('Location Name'),
                            prefixIcon: const Icon(Icons.store_outlined),
                          ),
                          validator: (v) =>
                              (v == null || v.trim().isEmpty)
                                  ? 'Location name is required'
                                  : null,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          controller: _shortCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Short Name',
                            prefixIcon: Icon(Icons.badge_outlined),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _locationType,
                          decoration: const InputDecoration(
                            labelText: 'Location Type',
                            prefixIcon: Icon(Icons.category_outlined),
                          ),
                          items: _locationTypes
                              .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                              .toList(),
                          onChanged: (v) => setState(() => _locationType = v),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _groupId,
                          decoration: const InputDecoration(
                            labelText: 'Location Group',
                            prefixIcon: Icon(Icons.account_tree_outlined),
                          ),
                          items: widget.groups
                              .map((g) => DropdownMenuItem(
                                  value: g['id'] as String, child: Text(g['group_name'] as String)))
                              .toList(),
                          onChanged: (v) => setState(() => _groupId = v),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  DropdownButtonFormField<String>(
                    initialValue: _responsibleUserId,
                    decoration: const InputDecoration(
                      labelText: 'Responsible User',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                    items: widget.users
                        .map((u) => DropdownMenuItem(
                            value: u['id'] as String, child: Text(u['full_name'] as String)))
                        .toList(),
                    onChanged: (v) => setState(() => _responsibleUserId = v),
                  ),
                  const SizedBox(height: 14),

                  TextFormField(
                    controller: _addr1Ctrl,
                    decoration: const InputDecoration(
                      labelText: 'Address Line 1',
                      prefixIcon: Icon(Icons.location_on_outlined),
                    ),
                  ),
                  const SizedBox(height: 14),

                  TextFormField(
                    controller: _addr2Ctrl,
                    decoration: const InputDecoration(
                      labelText: 'Address Line 2',
                      prefixIcon: Icon(Icons.location_on_outlined),
                    ),
                  ),
                  const SizedBox(height: 14),

                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 2,
                        child: DropdownButtonFormField<String>(
                          initialValue: _cityId,
                          decoration: const InputDecoration(
                            labelText: 'City',
                            prefixIcon: Icon(Icons.location_city_outlined),
                          ),
                          items: widget.cities
                              .map((c) => DropdownMenuItem(
                                  value: c['id'] as String, child: Text(c['city_name'] as String)))
                              .toList(),
                          onChanged: (v) => setState(() => _cityId = v),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: _postalCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Postal Code',
                            prefixIcon: Icon(Icons.pin_outlined),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _phoneCtrl,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(
                            labelText: 'Phone',
                            prefixIcon: Icon(Icons.phone_outlined),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: _emailCtrl,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(
                            labelText: 'Email',
                            prefixIcon: Icon(Icons.email_outlined),
                          ),
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) return null;
                            if (!v.contains('@')) return 'Enter a valid email';
                            return null;
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  TextFormField(
                    controller: _taxRegCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Tax Registration No.',
                      hintText: 'e.g. TVA/TIN for this branch',
                      prefixIcon: Icon(Icons.receipt_long_outlined),
                    ),
                  ),
                  const SizedBox(height: 14),

                  TextFormField(
                    controller: _serverCtrl,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Server URL',
                      hintText: 'e.g. http://192.168.1.100:3000',
                      prefixIcon: Icon(Icons.dns_outlined),
                      helperText: 'Local PostgREST URL for offline LAN access',
                    ),
                  ),
                  const SizedBox(height: 8),

                  Column(
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Allow Negative Stock', style: TextStyle(fontSize: 14)),
                        subtitle: const Text('Override — allow sales to take stock below zero at this location',
                            style: TextStyle(fontSize: 12)),
                        value: _negativeStockAllowed,
                        onChanged: (v) => setState(() => _negativeStockAllowed = v),
                        activeThumbColor: AppColors.positive,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // ── Actions ────────────────────────────────────────────
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                          onPressed: _saving
                              ? null
                              : () => Navigator.of(context, rootNavigator: true).pop(),
                          child: const Text('Cancel')),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 130,
                        child: ElevatedButton(
                          onPressed: _saving ? null : _save,
                          child: _saving
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2))
                              : Text(_isEdit ? 'Save Changes' : 'Add Location'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
