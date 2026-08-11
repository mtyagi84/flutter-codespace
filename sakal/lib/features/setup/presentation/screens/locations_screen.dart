import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/layout/screen_header.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../../../core/widgets/sakal_adaptive_list.dart';

const _locationTypes = ['Store', 'Warehouse', 'Office', 'Head Office', 'Distribution Centre'];

// No repository/model layer exists for this screen (it calls DioClient
// directly) — this row type is defined locally rather than introducing a
// new data/models file for a single screen. Groups/users/cities stay Map
// — dropdown lookup sources for this screen, not its own row type.
class Location {
  final String  id;
  final String  locationName;
  final String? locationShort;
  final String? locationType;
  final String? groupId;
  final String? groupName;
  final String? responsibleUserId;
  final String? addressLine1;
  final String? addressLine2;
  final String? cityId;
  final String? cityName;
  final String? postalCode;
  final String? phone;
  final String? email;
  final String? taxRegNumber;
  final String? serverUrl;
  final bool    isNegativeStockAllowed;
  final bool    isIssueAllowed;
  final bool    isActive;

  const Location({
    required this.id,
    required this.locationName,
    required this.locationShort,
    required this.locationType,
    required this.groupId,
    required this.groupName,
    required this.responsibleUserId,
    required this.addressLine1,
    required this.addressLine2,
    required this.cityId,
    required this.cityName,
    required this.postalCode,
    required this.phone,
    required this.email,
    required this.taxRegNumber,
    required this.serverUrl,
    required this.isNegativeStockAllowed,
    required this.isIssueAllowed,
    required this.isActive,
  });

  factory Location.fromJson(Map<String, dynamic> j) {
    final group = j['group'] as Map<String, dynamic>?;
    final city  = j['city']  as Map<String, dynamic>?;
    return Location(
      id:                     j['id']                         as String? ?? '',
      locationName:           j['location_name']              as String? ?? '',
      locationShort:          j['location_short']              as String?,
      locationType:           j['location_type']               as String?,
      groupId:                j['group_id']                    as String?,
      groupName:              group?['group_name']             as String?,
      responsibleUserId:      j['responsible_user_id']         as String?,
      addressLine1:           j['address_line1']               as String?,
      addressLine2:           j['address_line2']               as String?,
      cityId:                 j['city_id']                     as String?,
      cityName:               city?['city_name']                as String?,
      postalCode:             j['postal_code']                 as String?,
      phone:                  j['phone']                       as String?,
      email:                  j['email']                       as String?,
      taxRegNumber:           j['tax_reg_number']               as String?,
      serverUrl:              j['server_url']                  as String?,
      isNegativeStockAllowed: j['is_negative_stock_allowed']   as bool?   ?? false,
      isIssueAllowed:         j['is_issue_allowed']             as bool?   ?? true,
      isActive:               j['is_active']                   as bool?   ?? true,
    );
  }
}

class LocationsScreen extends ConsumerStatefulWidget {
  const LocationsScreen({super.key});

  @override
  ConsumerState<LocationsScreen> createState() => _LocationsScreenState();
}

class _LocationsScreenState extends ConsumerState<LocationsScreen>
    with ScreenPermissionMixin<LocationsScreen>, ScreenHeaderMixin<LocationsScreen> {
  @override String get screenName => '/setup/locations';

  @override
  ScreenHeaderInfo buildScreenHeader() {
    final offline = ref.read(sessionProvider)?.offlineMode ?? false;
    return ScreenHeaderInfo(
      title: 'Location Master',
      helpText: 'Manage stores, warehouses and offices under this company.',
      actions: [
        if (canAdd && !offline)
          ElevatedButton.icon(
            onPressed: () => _openDialog(),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add Location'),
          ),
      ],
    );
  }

  List<Location> _rows   = [];
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
          _rows    = (results[0].data as List)
              .map((j) => Location.fromJson(j as Map<String, dynamic>))
              .toList();
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

  Future<void> _toggleActive(Location row) async {
    final newVal = !row.isActive;
    try {
      await DioClient.instance.patch(
        '/ric_locations',
        queryParameters: {'id': 'eq.${row.id}'},
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

  void _openDialog([Location? existing]) {
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
    // Title/subtitle/Add-Location action live in the shared TopBar via
    // ScreenHeaderMixin — call every build so it tracks current state.
    refreshScreenHeader();
    final offline = ref.watch(sessionProvider)?.offlineMode ?? false;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
                const SizedBox(height: 16),
              ],
            ],
          ),
        ),
        // ── List — SakalAdaptiveList owns the loading/error/empty +
        // mobile-card/desktop-table switch; a raw fixed-width Row table
        // here overflowed by 616px on mobile since it never adapted at all.
        Expanded(
          child: SakalAdaptiveList<Location>(
            loading: _loading,
            error: null,
            rows: _rows,
            columns: const [
              SakalListColumn('Location Name', flex: 3),
              SakalListColumn('Short', flex: 1),
              SakalListColumn('Type', flex: 2),
              SakalListColumn('Group', flex: 2),
              SakalListColumn('Phone', flex: 2),
              SakalListColumn('Active', flex: 1),
              SakalListColumn('Actions', flex: 1),
            ],
            rowBuilder: (row, i) => _buildTableRow(row, canEdit && !offline),
            cardBuilder: (row) => _LocationCard(
              row: row,
              canEdit: canEdit && !offline,
              onEdit: () => _openDialog(row),
              onToggle: () => _toggleActive(row),
              onDelete: () => _confirmDelete(row.id),
            ),
            emptyState: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.store_mall_directory_outlined,
                      size: 40, color: AppColors.textSecondary),
                  SizedBox(height: 12),
                  Text('No locations yet.',
                      style: TextStyle(color: AppColors.textSecondary)),
                  Text('Click "Add Location" to create one.',
                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTableRow(Location row, bool canEditRow) {
    final active = row.isActive;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row.locationName,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
                if ((row.addressLine1 ?? '').isNotEmpty || row.cityName != null)
                  Text(
                    [
                      if ((row.addressLine1 ?? '').isNotEmpty) row.addressLine1!,
                      if (row.cityName != null) row.cityName!,
                    ].join(', '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                  ),
              ],
            ),
          ),
          Expanded(
            flex: 1,
            child: Text(row.locationShort ?? '—',
                style: const TextStyle(fontSize: 13, color: AppColors.textPrimary)),
          ),
          Expanded(flex: 2, child: _TypeChip(type: row.locationType)),
          Expanded(
            flex: 2,
            child: Text(row.groupName ?? '—',
                style: const TextStyle(fontSize: 13, color: AppColors.textPrimary),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            flex: 2,
            child: Text(row.phone ?? '—',
                style: const TextStyle(fontSize: 13, color: AppColors.textPrimary)),
          ),
          Expanded(
            flex: 1,
            child: Switch(
              value: active,
              onChanged: canEditRow ? (_) => _toggleActive(row) : null,
              activeThumbColor: AppColors.positive,
            ),
          ),
          Expanded(
            flex: 1,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined, size: 18, color: AppColors.primary),
                  onPressed: canEditRow ? () => _openDialog(row) : null,
                ),
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.negative),
                  onPressed: canEditRow ? () => _confirmDelete(row.id) : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(String id) async {
    final session = ref.read(sessionProvider);
    if (session == null) return;
    try {
      final res = await DioClient.instance.post(
        '/rpc/fn_can_delete_location',
        data: {'p_client_id': session.clientId, 'p_company_id': session.companyId, 'p_location_id': id},
      );
      final blockReason = res.data as String?;
      if (blockReason != null) {
        _showError(blockReason);
        return;
      }
    } on DioException catch (e) {
      _showError(ErrorPresenter.format(e, action: 'check whether this location can be deleted'));
      return;
    }
    if (!mounted) return;

    // Use the dialog's OWN builder context (ctx), not the enclosing
    // screen's — Navigator.pop(context, ...) here was popping the wrong
    // Navigator (the screen itself, via whatever Navigator is nearest to
    // LocationsScreen) instead of dismissing the dialog, producing a real
    // "click Yes -> blank screen" bug. See the same recurring pattern
    // documented in project memory (feedback_dialog_rootnavigator).
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Location?'),
        content: const Text(
            'This will mark the location as deleted. It will no longer appear in lists.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(true),
              child: const Text('Delete',
                  style: TextStyle(color: AppColors.negative))),
        ],
      ),
    );
    if (ok == true) _delete(id);
  }
}

// ── Mobile card ───────────────────────────────────────────────────────────────

class _LocationCard extends StatelessWidget {
  final Location row;
  final bool canEdit;
  final VoidCallback onEdit;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  const _LocationCard({
    required this.row,
    required this.canEdit,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final active = row.isActive;
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
                      Text(row.locationName,
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary)),
                      if ((row.addressLine1 ?? '').isNotEmpty || row.cityName != null)
                        Text(
                          [
                            if ((row.addressLine1 ?? '').isNotEmpty) row.addressLine1!,
                            if (row.cityName != null) row.cityName!,
                          ].join(', '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                        ),
                    ],
                  ),
                ),
                Switch(
                  value: active,
                  onChanged: canEdit ? (_) => onToggle() : null,
                  activeThumbColor: AppColors.positive,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _TypeChip(type: row.locationType),
                if ((row.locationShort ?? '').isNotEmpty)
                  Text(row.locationShort!,
                      style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                if (row.groupName != null)
                  Text(row.groupName!,
                      style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                if ((row.phone ?? '').isNotEmpty)
                  Text(row.phone!,
                      style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
            if (canEdit) ...[
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
  final Location? existing;
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
  bool    _issueAllowed = true;
  bool    _saving = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final d = widget.existing;
    if (d != null) {
      _nameCtrl.text   = d.locationName;
      _shortCtrl.text  = d.locationShort ?? '';
      _addr1Ctrl.text  = d.addressLine1  ?? '';
      _addr2Ctrl.text  = d.addressLine2  ?? '';
      _postalCtrl.text = d.postalCode    ?? '';
      _phoneCtrl.text  = d.phone         ?? '';
      _emailCtrl.text  = d.email         ?? '';
      _taxRegCtrl.text = d.taxRegNumber  ?? '';
      _serverCtrl.text = d.serverUrl     ?? '';
      _locationType    = d.locationType;
      _groupId         = d.groupId;
      _responsibleUserId = d.responsibleUserId;
      _cityId          = d.cityId;
      _negativeStockAllowed = d.isNegativeStockAllowed;
      _issueAllowed = d.isIssueAllowed;
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
      'is_issue_allowed':          _issueAllowed,
    };

    try {
      if (_isEdit) {
        await DioClient.instance.patch(
          '/ric_locations',
          queryParameters: {'id': 'eq.${widget.existing!.id}'},
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
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Allow Material Issue', style: TextStyle(fontSize: 14)),
                        subtitle: const Text('Whether this location can be a Material Requisition\'s From Location',
                            style: TextStyle(fontSize: 12)),
                        value: _issueAllowed,
                        onChanged: (v) => setState(() => _issueAllowed = v),
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
