import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/models/menu_models.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/permission_cascade.dart';
import '../../../../core/utils/responsive.dart';

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

  // ── Sales Controls (087_sales_order.sql: ric_user_sales_controls) ────────
  // Per-user price-override/discount/cost-visibility settings, separate
  // from the menu-feature grid above. Missing row = all false/0 (least-
  // privilege default, same convention as the feature grid).
  Map<String, dynamic>? _salesControls;
  String?  _salesControlsRowId; // null = no row yet, next save is an INSERT
  bool     _loadingSalesControls = false;
  bool     _savingSalesControls  = false;

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
    unawaited(_loadSalesControls(userId));
  }

  Future<void> _loadSalesControls(String userId) async {
    setState(() { _loadingSalesControls = true; _salesControls = null; _salesControlsRowId = null; });
    final session = ref.read(sessionProvider)!;
    try {
      final res = await DioClient.instance.get('/ric_user_sales_controls', queryParameters: {
        'client_id':  'eq.${session.clientId}',
        'company_id': 'eq.${session.companyId}',
        'user_id':    'eq.$userId',
        'is_deleted': 'eq.false',
        'select':     'id,can_override_price,can_give_discount,max_discount_percent,can_view_cost_price',
        'limit':      '1',
      });
      final list = res.data as List;
      if (mounted) {
        setState(() {
          if (list.isNotEmpty) {
            final row = list.first as Map<String, dynamic>;
            _salesControlsRowId = row['id'] as String;
            _salesControls = row;
          } else {
            _salesControls = {
              'can_override_price': false, 'can_give_discount': false,
              'max_discount_percent': null, 'can_view_cost_price': false,
            };
          }
          _loadingSalesControls = false;
        });
      }
    } on DioException {
      if (mounted) {
        setState(() {
          _salesControls = {
            'can_override_price': false, 'can_give_discount': false,
            'max_discount_percent': null, 'can_view_cost_price': false,
          };
          _loadingSalesControls = false;
        });
      }
    }
  }

  Future<void> _saveSalesControls(Map<String, dynamic> updated) async {
    if (_selectedUserId == null || _savingSalesControls) return;
    final previous = _salesControls;
    setState(() { _salesControls = updated; _savingSalesControls = true; });
    final session = ref.read(sessionProvider)!;
    final payload = {
      'can_override_price':   updated['can_override_price'],
      'can_give_discount':    updated['can_give_discount'],
      'max_discount_percent': updated['max_discount_percent'],
      'can_view_cost_price':  updated['can_view_cost_price'],
      'updated_by':           session.userId,
    };
    try {
      if (_salesControlsRowId != null) {
        await DioClient.instance.patch('/ric_user_sales_controls',
            queryParameters: {'id': 'eq.$_salesControlsRowId'}, data: payload);
      } else {
        final res = await DioClient.instance.post('/ric_user_sales_controls', data: {
          ...payload,
          'client_id':  session.clientId,
          'company_id': session.companyId,
          'user_id':    _selectedUserId,
          'created_by': session.userId,
        });
        final created = res.data;
        if (created is List && created.isNotEmpty) {
          _salesControlsRowId = (created.first as Map<String, dynamic>)['id'] as String?;
        } else {
          unawaited(_loadSalesControls(_selectedUserId!));
        }
      }
    } on DioException {
      if (mounted) {
        setState(() => _salesControls = previous);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not save Sales Controls. Please try again.'),
          backgroundColor: AppColors.negative,
        ));
      }
    } finally {
      if (mounted) setState(() => _savingSalesControls = false);
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
    final isMobile = Responsive.isMobile(context);
    return SingleChildScrollView(
      padding: EdgeInsets.all(isMobile ? 16 : 32),
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

              // ── Two-panel body — a fixed 220px Users column left almost
              // no room for the Expanded detail panel on mobile (down to
              // ~112px, the direct cause of the Sales Controls/permission
              // grid text wrapping one character per line). Stack instead
              // of side-by-side there.
              if (isMobile) ...[
                _buildUsersCard(),
                const SizedBox(height: 16),
                _buildDetailPanel(),
              ] else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 220, child: _buildUsersCard()),
                    const SizedBox(width: 16),
                    Expanded(child: _buildDetailPanel()),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUsersCard() {
    return Card(
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
    );
  }

  Widget _buildDetailPanel() {
    return _selectedUserId == null
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
                              // Mobile: Copy-from dropdown gets its own
                              // full-width row, Grant/Revoke share the row
                              // below — a fixed-width icon+label Row plus
                              // two full-text buttons never fits a narrow
                              // screen (real overflow reported live).
                              Builder(builder: (context) {
                                final isMobile =
                                    Responsive.isMobile(context);
                                final grantButton = OutlinedButton.icon(
                                  onPressed: _saving.isNotEmpty
                                      ? null
                                      : _grantAll,
                                  icon: const Icon(
                                      Icons.check_box_outlined,
                                      size: 16),
                                  label: const Text('Grant All'),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: AppColors.positive,
                                  ),
                                );
                                final revokeButton = OutlinedButton.icon(
                                  onPressed: _saving.isNotEmpty
                                      ? null
                                      : _revokeAll,
                                  icon: const Icon(
                                      Icons.check_box_outline_blank,
                                      size: 16),
                                  label: const Text('Revoke All'),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: AppColors.negative,
                                  ),
                                );
                                final copyDropdown = _CopyFromDropdown(
                                  users: _users,
                                  excludeId: _selectedUserId!,
                                  onCopy: _copyFrom,
                                );
                                return Card(
                                  shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(12)),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 12),
                                    child: isMobile
                                        ? Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment
                                                    .stretch,
                                            children: [
                                              copyDropdown,
                                              const SizedBox(height: 10),
                                              Row(
                                                children: [
                                                  Expanded(
                                                      child:
                                                          grantButton),
                                                  const SizedBox(
                                                      width: 8),
                                                  Expanded(
                                                      child:
                                                          revokeButton),
                                                ],
                                              ),
                                            ],
                                          )
                                        : Row(
                                            children: [
                                              Expanded(
                                                  child: copyDropdown),
                                              const SizedBox(width: 12),
                                              grantButton,
                                              const SizedBox(width: 8),
                                              revokeButton,
                                            ],
                                          ),
                                  ),
                                );
                              }),
                              const SizedBox(height: 12),

                              if (_error != null) ...[
                                _ErrorBanner(
                                    message: _error!,
                                    onRetry: () => _loadPermissions(
                                        _selectedUserId!)),
                                const SizedBox(height: 12),
                              ],

                              // ── Sales Controls ───────────────────────
                              _SalesControlsCard(
                                loading: _loadingSalesControls,
                                saving: _savingSalesControls,
                                values: _salesControls,
                                onChanged: _saveSalesControls,
                              ),
                              const SizedBox(height: 12),

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
                          );
  }
}

// ── Sales Controls card ─────────────────────────────────────────────────────
// Odoo has no single equivalent — price-editing is a plain field, discount
// limits are typically an Approvals-app workflow, and cost/margin
// visibility is its own dedicated group (sales_margin.group_sale_margin).
// This card assembles the equivalent of all three into one purpose-built
// per-user settings row (ric_user_sales_controls), consumed by
// fn_save_sales_order — see 087_sales_order.sql.
class _SalesControlsCard extends StatefulWidget {
  final bool loading;
  final bool saving;
  final Map<String, dynamic>? values;
  final ValueChanged<Map<String, dynamic>> onChanged;

  const _SalesControlsCard({
    required this.loading,
    required this.saving,
    required this.values,
    required this.onChanged,
  });

  @override
  State<_SalesControlsCard> createState() => _SalesControlsCardState();
}

class _SalesControlsCardState extends State<_SalesControlsCard> {
  late final TextEditingController _maxDiscountCtrl;

  @override
  void initState() {
    super.initState();
    _maxDiscountCtrl = TextEditingController(text: _fmtMaxDiscount(widget.values));
  }

  @override
  void didUpdateWidget(covariant _SalesControlsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.values != widget.values) {
      _maxDiscountCtrl.text = _fmtMaxDiscount(widget.values);
    }
  }

  @override
  void dispose() {
    _maxDiscountCtrl.dispose();
    super.dispose();
  }

  String _fmtMaxDiscount(Map<String, dynamic>? values) {
    final v = values?['max_discount_percent'];
    return v == null ? '' : (v as num).toString();
  }

  void _emit({bool? canOverride, bool? canDiscount, double? maxDiscount, bool? canViewCost}) {
    final v = widget.values ?? const {};
    widget.onChanged({
      'can_override_price':   canOverride  ?? v['can_override_price']   as bool? ?? false,
      'can_give_discount':    canDiscount  ?? v['can_give_discount']    as bool? ?? false,
      'max_discount_percent': maxDiscount  ?? (v['max_discount_percent'] as num?)?.toDouble(),
      'can_view_cost_price':  canViewCost  ?? v['can_view_cost_price']  as bool? ?? false,
    });
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.values;
    final canOverride = v?['can_override_price'] as bool? ?? false;
    final canDiscount = v?['can_give_discount'] as bool? ?? false;
    final canViewCost = v?['can_view_cost_price'] as bool? ?? false;

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.sell_outlined, size: 16, color: AppColors.textSecondary),
            const SizedBox(width: 8),
            const Text('Sales Controls', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
            const SizedBox(width: 8),
            if (widget.saving) const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
          const SizedBox(height: 2),
          const Text(
            'Governs price/discount behavior on Sales Order — not part of the menu grid below.',
            style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 10),
          if (widget.loading)
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Center(child: CircularProgressIndicator()))
          else
            Column(children: [
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Can override price', style: TextStyle(fontSize: 13)),
                subtitle: const Text('Type a rate manually on a Direct Sales Order line, even when Price Master has (or lacks) an active price',
                    style: TextStyle(fontSize: 11)),
                value: canOverride,
                onChanged: widget.saving ? null : (v) => _emit(canOverride: v),
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Can give discount', style: TextStyle(fontSize: 13)),
                subtitle: const Text('Shows the Discount % field on Sales Order lines', style: TextStyle(fontSize: 11)),
                value: canDiscount,
                onChanged: widget.saving ? null : (v) => _emit(canDiscount: v),
              ),
              if (canDiscount) Padding(
                padding: const EdgeInsets.only(left: 16, bottom: 8),
                child: SizedBox(
                  width: 220,
                  child: TextFormField(
                    controller: _maxDiscountCtrl,
                    enabled: !widget.saving,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Max Discount %  (blank = unlimited)',
                      isDense: true,
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    ),
                    style: const TextStyle(fontSize: 13),
                    onFieldSubmitted: (text) => _emit(maxDiscount: text.trim().isEmpty ? null : double.tryParse(text.trim())),
                    onEditingComplete: () => _emit(maxDiscount: _maxDiscountCtrl.text.trim().isEmpty ? null : double.tryParse(_maxDiscountCtrl.text.trim())),
                  ),
                ),
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Can view cost price', style: TextStyle(fontSize: 13)),
                subtitle: const Text('Shows Cost Price / Margin on Sales Order lines — hidden by never fetching it otherwise',
                    style: TextStyle(fontSize: 11)),
                value: canViewCost,
                onChanged: widget.saving ? null : (v) => _emit(canViewCost: v),
              ),
            ]),
        ]),
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
            ? AppColors.primary.withValues(alpha: 0.08)
            : Colors.transparent,
        child: Row(
          children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: isSelected
                  ? AppColors.primary
                  : AppColors.primary.withValues(alpha: 0.12),
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
                color: AppColors.primary.withValues(alpha: 0.06),
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
            Builder(builder: (context) {
              final grid = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Column header ────────────────────────────
                  _PermHeader(),

                  // ── Groups ───────────────────────────────────
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
                                AppColors.surfaceVariant.withValues(alpha: 0.6),
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
              );

              // 6 fixed-width boolean columns (View/Add/Edit/Approve/Copy/
              // Excel) plus a Feature-name column never fit a phone width —
              // there's no card-style simplification that keeps every
              // permission visible, so scroll horizontally on mobile instead
              // of letting the Feature-name column squeeze into a vertical
              // letter-wrap (real bug: "Product Category Level Setup"
              // wrapping one word per line at ~325px). Desktop is already
              // wide enough (Expanded fills it) — leave it untouched.
              if (!Responsive.isMobile(context)) return grid;
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(width: 520, child: grid),
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
      child: const Row(
        children: [
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
          : AppColors.surfaceVariant.withValues(alpha: 0.3),
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
              fillColor: WidgetStateProperty.all(AppColors.primary),
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
