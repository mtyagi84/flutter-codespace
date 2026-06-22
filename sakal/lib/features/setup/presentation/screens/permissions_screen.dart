import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/models/menu_models.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/permission_cascade.dart';

class PermissionsScreen extends ConsumerStatefulWidget {
  const PermissionsScreen({super.key});

  @override
  ConsumerState<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends ConsumerState<PermissionsScreen> {
  List<Map<String, dynamic>>         _users    = [];
  // Keyed by feature_code for O(1) toggle updates
  Map<String, Map<String, dynamic>>  _features = {};
  String? _selectedUserId;
  final Set<String> _saving = {};
  bool    _loadingUsers = true;
  bool    _loadingPerms = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadUsers());
  }

  // ── Data loading ─────────────────────────────────────────────────────────

  Future<void> _loadUsers() async {
    final session = ref.read(sessionProvider)!;
    try {
      final res = await DioClient.instance.get('/rim_users', queryParameters: {
        'client_id':  'eq.${session.clientId}',
        'company_id': 'eq.${session.companyId}',
        'is_deleted': 'eq.false',
        'select':     'id,full_name,salutation,is_active',
        'order':      'full_name.asc',
      });
      if (mounted) {
        setState(() {
          _users        = List<Map<String, dynamic>>.from(res.data as List);
          _loadingUsers = false;
        });
      }
    } on DioException {
      if (mounted) {
        setState(() { _loadingUsers = false; _error = 'Could not load users.'; });
      }
    }
  }

  Future<void> _loadPermissions(String userId) async {
    setState(() {
      _loadingPerms    = true;
      _features        = {};
      _selectedUserId  = userId;
      _error           = null;
    });
    final session = ref.read(sessionProvider)!;
    try {
      final res = await DioClient.instance.post(
        '/rpc/fn_get_user_permissions',
        data: {
          'p_user_id':    userId,
          'p_client_id':  session.clientId,
          'p_company_id': session.companyId,
        },
      );
      final list = List<Map<String, dynamic>>.from(res.data as List);
      if (mounted) {
        setState(() {
          _features     = {for (final f in list) f['feature_code'] as String: f};
          _loadingPerms = false;
        });
      }
    } on DioException {
      if (mounted) {
        setState(() { _loadingPerms = false; _error = 'Could not load permissions.'; });
      }
    }
  }

  // ── Menu refresh (when editing own permissions) ───────────────────────────

  Future<void> _refreshMenuIfSelf() async {
    final session = ref.read(sessionProvider)!;
    if (_selectedUserId != session.userId) return;
    try {
      final res = await DioClient.instance.post('/rpc/fn_get_user_menu', data: {
        'p_user_id':    session.userId,
        'p_client_id':  session.clientId,
        'p_company_id': session.companyId,
      });
      final menuList = (res.data as List<dynamic>)
          .map((e) => MenuModule.fromJson(e as Map<String, dynamic>))
          .toList();
      if (mounted) ref.read(menuProvider.notifier).state = menuList;
    } catch (_) {}
  }

  // ── Permission toggle (auto-save) ─────────────────────────────────────────

  Future<void> _toggle(String featureCode, String field) async {
    final row = _features[featureCode];
    if (row == null || _saving.contains(featureCode)) return;

    final updated = applyPermissionToggle({
      'view_allowed':         row['view_allowed']        as bool? ?? false,
      'add_allowed':          row['add_allowed']          as bool? ?? false,
      'edit_allowed':         row['edit_allowed']         as bool? ?? false,
      'approve_allowed':      row['approve_allowed']      as bool? ?? false,
      'copy_allowed':         row['copy_allowed']         as bool? ?? false,
      'excel_upload_allowed': row['excel_upload_allowed'] as bool? ?? false,
    }, field);

    // Optimistic update
    setState(() {
      _saving.add(featureCode);
      _features[featureCode] = {...row, ...updated};
    });

    final session = ref.read(sessionProvider)!;
    try {
      await DioClient.instance.post('/rpc/fn_upsert_user_permission', data: {
        'p_client_id':            session.clientId,
        'p_company_id':           session.companyId,
        'p_user_id':              _selectedUserId,
        'p_module_id':            row['module_id'],
        'p_feature_code':         featureCode,
        'p_view_allowed':         updated['view_allowed'],
        'p_add_allowed':          updated['add_allowed'],
        'p_edit_allowed':         updated['edit_allowed'],
        'p_approve_allowed':      updated['approve_allowed'],
        'p_copy_allowed':         updated['copy_allowed'],
        'p_excel_upload_allowed': updated['excel_upload_allowed'],
        'p_updated_by':           session.userId,
      });
      unawaited(_refreshMenuIfSelf());
    } on DioException {
      if (mounted) {
        setState(() => _features[featureCode] = row); // revert
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not save permission. Please try again.'),
          backgroundColor: AppColors.negative,
        ));
      }
    } finally {
      if (mounted) setState(() => _saving.remove(featureCode));
    }
  }

  // ── Grant / Revoke all ────────────────────────────────────────────────────

  Future<void> _grantAll() async {
    if (_selectedUserId == null || _saving.isNotEmpty) return;
    final session = ref.read(sessionProvider)!;

    setState(() {
      for (final key in _features.keys) {
        _features[key] = {
          ..._features[key]!,
          'view_allowed': true,
          'add_allowed':  true,
          'edit_allowed': true,
        };
        _saving.add(key);
      }
    });

    try {
      for (final f in _features.values) {
        await DioClient.instance.post('/rpc/fn_upsert_user_permission', data: {
          'p_client_id':            session.clientId,
          'p_company_id':           session.companyId,
          'p_user_id':              _selectedUserId,
          'p_module_id':            f['module_id'],
          'p_feature_code':         f['feature_code'],
          'p_view_allowed':         true,
          'p_add_allowed':          true,
          'p_edit_allowed':         true,
          'p_approve_allowed':      f['approve_allowed'],
          'p_copy_allowed':         f['copy_allowed'],
          'p_excel_upload_allowed': f['excel_upload_allowed'],
          'p_updated_by':           session.userId,
        });
      }
      unawaited(_refreshMenuIfSelf());
    } on DioException {
      if (mounted) _loadPermissions(_selectedUserId!);
    } finally {
      if (mounted) setState(() => _saving.clear());
    }
  }

  Future<void> _revokeAll() async {
    if (_selectedUserId == null || _saving.isNotEmpty) return;
    final session = ref.read(sessionProvider)!;

    setState(() {
      for (final key in _features.keys) {
        _features[key] = {
          ..._features[key]!,
          'view_allowed':         false,
          'add_allowed':          false,
          'edit_allowed':         false,
          'approve_allowed':      false,
          'copy_allowed':         false,
          'excel_upload_allowed': false,
        };
        _saving.add(key);
      }
    });

    try {
      for (final f in _features.values) {
        await DioClient.instance.post('/rpc/fn_upsert_user_permission', data: {
          'p_client_id':            session.clientId,
          'p_company_id':           session.companyId,
          'p_user_id':              _selectedUserId,
          'p_module_id':            f['module_id'],
          'p_feature_code':         f['feature_code'],
          'p_view_allowed':         false,
          'p_add_allowed':          false,
          'p_edit_allowed':         false,
          'p_approve_allowed':      false,
          'p_copy_allowed':         false,
          'p_excel_upload_allowed': false,
          'p_updated_by':           session.userId,
        });
      }
      unawaited(_refreshMenuIfSelf());
    } on DioException {
      if (mounted) _loadPermissions(_selectedUserId!);
    } finally {
      if (mounted) setState(() => _saving.clear());
    }
  }

  // ── Copy from user ────────────────────────────────────────────────────────

  Future<void> _copyFrom(String fromUserId) async {
    if (_selectedUserId == null) return;
    final session = ref.read(sessionProvider)!;
    setState(() { _loadingPerms = true; });
    try {
      await DioClient.instance.post('/rpc/fn_copy_user_permissions', data: {
        'p_from_user_id': fromUserId,
        'p_to_user_id':   _selectedUserId,
        'p_client_id':    session.clientId,
        'p_company_id':   session.companyId,
        'p_copied_by':    session.userId,
      });
      await _loadPermissions(_selectedUserId!);
      unawaited(_refreshMenuIfSelf());
    } on DioException {
      if (mounted) {
        setState(() { _loadingPerms = false; });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not copy permissions. Please try again.'),
          backgroundColor: AppColors.negative,
        ));
      }
    }
  }

  // ── Build grouped module structure ────────────────────────────────────────
  // API returns sorted (module serial_no → group serial_no → feature serial_no).
  // We iterate in that order to preserve sort without re-sorting.

  List<_Module> _buildGrouped() {
    final Map<String, _Module> modules = {};

    for (final f in _features.values) {
      final mc = f['module_code'] as String;
      final gc = f['group_code']  as String? ?? '';

      modules.putIfAbsent(mc, () => _Module(
        code:     mc,
        name:     f['module_name']     as String,
        serialNo: f['module_serial_no'] as int? ?? 0,
      ));

      modules[mc]!.groups.putIfAbsent(gc, () => _Group(
        code:     gc,
        name:     f['group_name']      as String? ?? '',
        serialNo: f['group_serial_no'] as int? ?? 0,
      ));

      modules[mc]!.groups[gc]!.featureCodes.add(f['feature_code'] as String);
    }

    return modules.values.toList();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Page header ───────────────────────────────────────────
              const Text('User Permissions',
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary)),
              const SizedBox(height: 4),
              const Text(
                'Control what each user can view, edit, approve, copy and upload.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 24),

              if (_error != null && _selectedUserId == null) ...[
                _ErrorBanner(message: _error!, onRetry: _loadUsers),
                const SizedBox(height: 20),
              ],

              // ── Two-panel body ────────────────────────────────────────
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Left: User list ─────────────────────────────────
                  SizedBox(
                    width: 220,
                    child: Card(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 14),
                            decoration: const BoxDecoration(
                              color: AppColors.surfaceVariant,
                              borderRadius: BorderRadius.vertical(
                                  top: Radius.circular(12)),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.group_outlined,
                                    size: 16,
                                    color: AppColors.textSecondary),
                                SizedBox(width: 8),
                                Text('Users',
                                    style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.textPrimary)),
                              ],
                            ),
                          ),
                          const Divider(height: 1),
                          if (_loadingUsers)
                            const Padding(
                              padding: EdgeInsets.all(24),
                              child: Center(
                                  child: CircularProgressIndicator()),
                            )
                          else if (_users.isEmpty)
                            const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('No users found.',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: AppColors.textSecondary)),
                            )
                          else
                            ..._users.map((u) => _UserTile(
                                  user: u,
                                  isSelected:
                                      u['id'] == _selectedUserId,
                                  onTap: () => _loadPermissions(
                                      u['id'] as String),
                                )),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),

                  // ── Right: Permissions panel ────────────────────────
                  Expanded(
                    child: _selectedUserId == null
                        ? Card(
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            child: const SizedBox(
                              height: 320,
                              child: Center(
                                child: Column(
                                  mainAxisAlignment:
                                      MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.person_search_outlined,
                                        size: 48,
                                        color: AppColors.textSecondary),
                                    SizedBox(height: 12),
                                    Text(
                                      'Select a user to manage permissions',
                                      style: TextStyle(
                                          color:
                                              AppColors.textSecondary),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          )
                        : Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              // ── Action bar ──────────────────────────
                              Card(
                                shape: RoundedRectangleBorder(
                                    borderRadius:
                                        BorderRadius.circular(12)),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 12),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: _CopyFromDropdown(
                                          users: _users,
                                          excludeId: _selectedUserId!,
                                          onCopy: _copyFrom,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      OutlinedButton.icon(
                                        onPressed: _saving.isNotEmpty
                                            ? null
                                            : _grantAll,
                                        icon: const Icon(
                                            Icons.check_box_outlined,
                                            size: 16),
                                        label:
                                            const Text('Grant All'),
                                        style:
                                            OutlinedButton.styleFrom(
                                          foregroundColor:
                                              AppColors.positive,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      OutlinedButton.icon(
                                        onPressed: _saving.isNotEmpty
                                            ? null
                                            : _revokeAll,
                                        icon: const Icon(
                                            Icons
                                                .check_box_outline_blank,
                                            size: 16),
                                        label:
                                            const Text('Revoke All'),
                                        style:
                                            OutlinedButton.styleFrom(
                                          foregroundColor:
                                              AppColors.negative,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),

                              if (_error != null) ...[
                                _ErrorBanner(
                                    message: _error!,
                                    onRetry: () => _loadPermissions(
                                        _selectedUserId!)),
                                const SizedBox(height: 12),
                              ],

                              // ── Module cards ─────────────────────────
                              if (_loadingPerms)
                                Card(
                                  shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(12)),
                                  child: const Padding(
                                    padding: EdgeInsets.all(40),
                                    child: Center(
                                        child:
                                            CircularProgressIndicator()),
                                  ),
                                )
                              else if (_features.isEmpty)
                                Card(
                                  shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(12)),
                                  child: const Padding(
                                    padding: EdgeInsets.all(40),
                                    child: Center(
                                      child: Text(
                                        'No features found. Ensure master menus are seeded.',
                                        style: TextStyle(
                                            color: AppColors
                                                .textSecondary),
                                      ),
                                    ),
                                  ),
                                )
                              else
                                ..._buildGrouped().map((mod) =>
                                    _ModuleCard(
                                      module: mod,
                                      features: _features,
                                      saving: _saving,
                                      onToggle: _toggle,
                                    )),
                            ],
                          ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Data models ───────────────────────────────────────────────────────────────

class _Module {
  final String code;
  final String name;
  final int    serialNo;
  final Map<String, _Group> groups = {};
  _Module({required this.code, required this.name, required this.serialNo});
}

class _Group {
  final String       code;
  final String       name;
  final int          serialNo;
  final List<String> featureCodes = [];
  _Group({required this.code, required this.name, required this.serialNo});
}

// ── User tile ─────────────────────────────────────────────────────────────────

class _UserTile extends StatelessWidget {
  final Map<String, dynamic> user;
  final bool                 isSelected;
  final VoidCallback         onTap;

  const _UserTile({
    required this.user,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final name   = user['full_name'] as String? ?? '';
    final active = user['is_active'] as bool?   ?? true;

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        color: isSelected
            ? AppColors.primary.withOpacity(0.08)
            : Colors.transparent,
        child: Row(
          children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: isSelected
                  ? AppColors.primary
                  : AppColors.primary.withOpacity(0.12),
              child: Text(
                name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color:
                        isSelected ? Colors.white : AppColors.primary),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: isSelected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: isSelected
                              ? AppColors.primary
                              : AppColors.textPrimary)),
                  if (!active)
                    const Text('Inactive',
                        style: TextStyle(
                            fontSize: 10, color: AppColors.negative)),
                ],
              ),
            ),
            if (isSelected)
              const Icon(Icons.chevron_right,
                  size: 16, color: AppColors.primary),
          ],
        ),
      ),
    );
  }
}

// ── Copy-from dropdown ────────────────────────────────────────────────────────

class _CopyFromDropdown extends StatefulWidget {
  final List<Map<String, dynamic>> users;
  final String                     excludeId;
  final ValueChanged<String>       onCopy;

  const _CopyFromDropdown({
    required this.users,
    required this.excludeId,
    required this.onCopy,
  });

  @override
  State<_CopyFromDropdown> createState() => _CopyFromDropdownState();
}

class _CopyFromDropdownState extends State<_CopyFromDropdown> {
  String? _selected;

  @override
  void didUpdateWidget(_CopyFromDropdown old) {
    super.didUpdateWidget(old);
    // Reset when the selected user changes
    if (old.excludeId != widget.excludeId) _selected = null;
  }

  @override
  Widget build(BuildContext context) {
    final others = widget.users
        .where((u) => u['id'] != widget.excludeId)
        .toList();

    return Row(
      children: [
        const Icon(Icons.copy_outlined,
            size: 15, color: AppColors.textSecondary),
        const SizedBox(width: 8),
        const Text('Copy from:',
            style: TextStyle(
                fontSize: 13, color: AppColors.textSecondary)),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _selected,
              hint: const Text('Select user…',
                  style: TextStyle(fontSize: 13)),
              isExpanded: true,
              items: others
                  .map((u) => DropdownMenuItem(
                        value: u['id'] as String,
                        child: Text(
                          u['full_name'] as String? ?? '',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ))
                  .toList(),
              onChanged: (v) {
                if (v == null) return;
                setState(() => _selected = null);
                widget.onCopy(v);
              },
            ),
          ),
        ),
      ],
    );
  }
}

// ── Module card ───────────────────────────────────────────────────────────────

class _ModuleCard extends StatefulWidget {
  final _Module                              module;
  final Map<String, Map<String, dynamic>>   features;
  final Set<String>                          saving;
  final void Function(String, String)        onToggle;

  const _ModuleCard({
    required this.module,
    required this.features,
    required this.saving,
    required this.onToggle,
  });

  @override
  State<_ModuleCard> createState() => _ModuleCardState();
}

class _ModuleCardState extends State<_ModuleCard> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final sortedGroups = widget.module.groups.values.toList()
      ..sort((a, b) => a.serialNo.compareTo(b.serialNo));

    final radius = BorderRadius.circular(12);
    final bottomRadius = _expanded
        ? const BorderRadius.vertical(top: Radius.circular(12))
        : radius;

    return Card(
      shape: RoundedRectangleBorder(borderRadius: radius),
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Module header ──────────────────────────────────────────
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: bottomRadius,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.06),
                borderRadius: bottomRadius,
              ),
              child: Row(
                children: [
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 20,
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    widget.module.name.toUpperCase(),
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primary,
                        letterSpacing: 0.6),
                  ),
                ],
              ),
            ),
          ),

          if (_expanded) ...[
            const Divider(height: 1),

            // ── Column header ──────────────────────────────────────
            _PermHeader(),

            // ── Groups ─────────────────────────────────────────────
            ...sortedGroups.map((group) {
              final featureRows = group.featureCodes
                  .asMap()
                  .entries
                  .where((e) => widget.features.containsKey(e.value))
                  .toList();

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (group.name.isNotEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 7),
                      color:
                          AppColors.surfaceVariant.withOpacity(0.6),
                      child: Text(
                        group.name,
                        style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textSecondary,
                            letterSpacing: 0.3),
                      ),
                    ),
                  ...featureRows.map((e) {
                    final fc = e.value;
                    final f  = widget.features[fc]!;
                    return _FeatureRow(
                      feature:  f,
                      isEven:   e.key.isEven,
                      saving:   widget.saving.contains(fc),
                      onToggle: (field) => widget.onToggle(fc, field),
                    );
                  }),
                ],
              );
            }),
          ],
        ],
      ),
    );
  }
}

// ── Permission table header ───────────────────────────────────────────────────

class _PermHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      color: AppColors.surfaceVariant,
      child: Row(
        children: const [
          Expanded(
            child: Text('Feature',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary)),
          ),
          SizedBox(width: 70,  child: _CH('View')),
          SizedBox(width: 70,  child: _CH('Add')),
          SizedBox(width: 70,  child: _CH('Edit')),
          SizedBox(width: 80,  child: _CH('Approve')),
          SizedBox(width: 70,  child: _CH('Copy')),
          SizedBox(width: 80,  child: _CH('Excel')),
        ],
      ),
    );
  }
}

class _CH extends StatelessWidget {
  final String text;
  const _CH(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text,
        textAlign: TextAlign.center,
        style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.textSecondary));
  }
}

// ── Feature row ───────────────────────────────────────────────────────────────

class _FeatureRow extends StatelessWidget {
  final Map<String, dynamic> feature;
  final bool                 isEven;
  final bool                 saving;
  final ValueChanged<String> onToggle;

  const _FeatureRow({
    required this.feature,
    required this.isEven,
    required this.saving,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final masterApprove = feature['master_approve'] as bool? ?? false;
    final masterCopy    = feature['master_copy']    as bool? ?? false;
    final masterExcel   = feature['master_excel']   as bool? ?? false;

    return Container(
      color: isEven
          ? Colors.transparent
          : AppColors.surfaceVariant.withOpacity(0.3),
      padding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              feature['feature_name'] as String? ?? '',
              style: const TextStyle(
                  fontSize: 13, color: AppColors.textPrimary),
            ),
          ),
          SizedBox(
            width: 70,
            child: _PBox(
              value:    feature['view_allowed'] as bool? ?? false,
              enabled:  !saving,
              onToggle: () => onToggle('view_allowed'),
            ),
          ),
          SizedBox(
            width: 70,
            child: _PBox(
              value:    feature['add_allowed'] as bool? ?? false,
              enabled:  !saving,
              onToggle: () => onToggle('add_allowed'),
            ),
          ),
          SizedBox(
            width: 70,
            child: _PBox(
              value:    feature['edit_allowed'] as bool? ?? false,
              enabled:  !saving,
              onToggle: () => onToggle('edit_allowed'),
            ),
          ),
          SizedBox(
            width: 80,
            child: masterApprove
                ? _PBox(
                    value:    feature['approve_allowed'] as bool? ?? false,
                    enabled:  !saving,
                    onToggle: () => onToggle('approve_allowed'),
                  )
                : const _Dash(),
          ),
          SizedBox(
            width: 70,
            child: masterCopy
                ? _PBox(
                    value:    feature['copy_allowed'] as bool? ?? false,
                    enabled:  !saving,
                    onToggle: () => onToggle('copy_allowed'),
                  )
                : const _Dash(),
          ),
          SizedBox(
            width: 80,
            child: masterExcel
                ? _PBox(
                    value:    feature['excel_upload_allowed'] as bool? ?? false,
                    enabled:  !saving,
                    onToggle: () => onToggle('excel_upload_allowed'),
                  )
                : const _Dash(),
          ),
        ],
      ),
    );
  }
}

// ── Permission checkbox ───────────────────────────────────────────────────────

class _PBox extends StatelessWidget {
  final bool         value;
  final bool         enabled;
  final VoidCallback onToggle;

  const _PBox({
    required this.value,
    required this.enabled,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: enabled
          ? Checkbox(
              value: value,
              onChanged: (_) => onToggle(),
              activeColor: AppColors.primary,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            )
          : const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
    );
  }
}

class _Dash extends StatelessWidget {
  const _Dash();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text('—',
          style: TextStyle(
              fontSize: 13, color: AppColors.textSecondary)),
    );
  }
}

// ── Error banner ──────────────────────────────────────────────────────────────

class _ErrorBanner extends StatelessWidget {
  final String     message;
  final VoidCallback onRetry;

  const _ErrorBanner({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.negative.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.negative.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline,
              color: AppColors.negative, size: 18),
          const SizedBox(width: 10),
          Expanded(
              child: Text(message,
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.negative))),
          TextButton(
              onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
