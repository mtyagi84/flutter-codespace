import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/database/datasources/generic_lookup_local_ds.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';

class LocationGroupsScreen extends ConsumerStatefulWidget {
  const LocationGroupsScreen({super.key});

  @override
  ConsumerState<LocationGroupsScreen> createState() => _LocationGroupsScreenState();
}

class _LocationGroupsScreenState extends ConsumerState<LocationGroupsScreen>
    with ScreenPermissionMixin<LocationGroupsScreen> {
  @override String get screenName => '/setup/location-groups';

  List<Map<String, dynamic>> _rows  = [];
  List<Map<String, dynamic>> _users = [];
  String  _interLocationModel = 'SIMPLE';
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
      List<Map<String, dynamic>> rows;
      List<Map<String, dynamic>> users;

      if (session.offlineMode && !kIsWeb) {
        final local = GenericLookupLocalDs(ref.read(appDatabaseProvider));
        rows  = await local.getLookups(cacheKey: 'LOCATION_GROUPS', clientId: session.clientId, companyId: session.companyId);
        users = await local.getLookups(cacheKey: 'USERS', clientId: session.clientId, companyId: session.companyId);
      } else {
        final results = await Future.wait([
          DioClient.instance.get('/ric_location_groups', queryParameters: {
            'client_id':  'eq.${session.clientId}',
            'company_id': 'eq.${session.companyId}',
            'is_deleted': 'eq.false',
            'select':     '*,'
                'responsible:rim_users!responsible_user_id(full_name),'
                'customer_account:rim_accounts!customer_account_id(account_code,account_name),'
                'supplier_account:rim_accounts!supplier_account_id(account_code,account_name)',
            'order':      'group_name.asc',
          }),
          DioClient.instance.get('/rim_users', queryParameters: {
            'client_id':  'eq.${session.clientId}',
            'company_id': 'eq.${session.companyId}',
            'is_deleted': 'eq.false',
            'select':     'id,full_name',
            'order':      'full_name.asc',
          }),
        ]);
        rows  = List<Map<String, dynamic>>.from(results[0].data as List);
        users = List<Map<String, dynamic>>.from(results[1].data as List);

        if (!kIsWeb) {
          final local = GenericLookupLocalDs(ref.read(appDatabaseProvider));
          unawaited(local.upsertLookups(
            cacheKey: 'LOCATION_GROUPS', rows: rows, idOf: (r) => r['id'] as String,
            labelOf: (r) => r['group_name'] as String? ?? '',
            clientId: session.clientId, companyId: session.companyId,
          ));
          unawaited(local.upsertLookups(
            cacheKey: 'USERS', rows: users, idOf: (r) => r['id'] as String,
            labelOf: (r) => r['full_name'] as String? ?? '',
            clientId: session.clientId, companyId: session.companyId,
          ));
        }
      }

      // Company setup (inter_location_model) is a single small config value,
      // not a list lookup — stays remote-only; harmless default if unavailable.
      String interLocationModel = 'SIMPLE';
      if (!session.offlineMode) {
        final companyRes = await DioClient.instance.get('/ric_companies', queryParameters: {
          'id':     'eq.${session.companyId}',
          'select': 'inter_location_model',
          'limit':  '1',
        });
        final companyList = companyRes.data as List<dynamic>;
        interLocationModel = companyList.isNotEmpty
            ? (companyList.first as Map<String, dynamic>)['inter_location_model'] as String? ?? 'SIMPLE'
            : 'SIMPLE';
      }

      if (mounted) {
        setState(() {
          _rows  = rows;
          _users = users;
          _interLocationModel = interLocationModel;
          _loading = false;
        });
      }
    } on DioException {
      if (mounted) setState(() { _loading = false; _error = 'Could not load location groups.'; });
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppColors.negative),
    );
  }

  Future<void> _save(Map<String, dynamic> payload, {
    required Map<String, dynamic>? existing,
  }) async {
    final session = ref.read(sessionProvider)!;
    final now     = DateTime.now().toUtc().toIso8601String();
    final id      = payload['id'] as String;

    try {
      if (existing != null) {
        await DioClient.instance.patch(
          '/ric_location_groups',
          queryParameters: {'id': 'eq.$id'},
          data: {...payload, 'updated_at': now, 'updated_by': session.userId}
            ..remove('id')..remove('client_id')..remove('company_id'),
          options: Options(headers: {'Prefer': 'return=minimal'}),
        );
      } else {
        await DioClient.instance.post(
          '/ric_location_groups',
          data: {
            ...payload,
            'client_id':  session.clientId,
            'company_id': session.companyId,
            'is_deleted': false,
            'created_at': now,
            'created_by': session.userId,
          },
          options: Options(headers: {'Prefer': 'return=minimal'}),
        );
      }

      // Keep rim_accounts.inter_entity_group_id in sync with this group's
      // chosen customer/supplier accounts (bidirectional link).
      final oldCustomer = existing?['customer_account_id'] as String?;
      final oldSupplier = existing?['supplier_account_id'] as String?;
      final newCustomer = payload['customer_account_id'] as String?;
      final newSupplier = payload['supplier_account_id'] as String?;

      for (final oldId in {oldCustomer, oldSupplier}) {
        if (oldId != null && oldId != newCustomer && oldId != newSupplier) {
          await DioClient.instance.patch('/rim_accounts',
              queryParameters: {'id': 'eq.$oldId', 'inter_entity_group_id': 'eq.$id'},
              data: {'inter_entity_group_id': null},
              options: Options(headers: {'Prefer': 'return=minimal'}));
        }
      }
      for (final newId in {newCustomer, newSupplier}) {
        if (newId != null) {
          await DioClient.instance.patch('/rim_accounts',
              queryParameters: {'id': 'eq.$newId'},
              data: {'inter_entity_group_id': id},
              options: Options(headers: {'Prefer': 'return=minimal'}));
        }
      }

      ref.invalidate(accountsProvider);
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      _load();
    } on DioException catch (e) {
      final msg = e.response?.data?['message'] as String? ?? 'Save failed. Please try again.';
      _showError(msg);
    } catch (e) {
      _showError('Unexpected error: $e');
    }
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final id = row['id'] as String;
    try {
      await DioClient.instance.patch(
        '/ric_location_groups',
        queryParameters: {'id': 'eq.$id'},
        data: {'is_deleted': true, 'updated_at': DateTime.now().toUtc().toIso8601String()},
        options: Options(headers: {'Prefer': 'return=minimal'}),
      );
      for (final accId in {row['customer_account_id'] as String?, row['supplier_account_id'] as String?}) {
        if (accId != null) {
          await DioClient.instance.patch('/rim_accounts',
              queryParameters: {'id': 'eq.$accId', 'inter_entity_group_id': 'eq.$id'},
              data: {'inter_entity_group_id': null},
              options: Options(headers: {'Prefer': 'return=minimal'}));
        }
      }
      _load();
    } on DioException {
      _showError('Could not delete location group.');
    }
  }

  Future<void> _confirmDelete(Map<String, dynamic> row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Location Group?'),
        content: Text('Remove "${row['group_name']}"? Locations assigned to this group will need to be reassigned.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete', style: TextStyle(color: AppColors.negative))),
        ],
      ),
    );
    if (ok == true) _delete(row);
  }

  void _openDialog([Map<String, dynamic>? existing]) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _LocationGroupDialog(
        existing: existing,
        users: _users,
        interLocationModel: _interLocationModel,
        onSave: (payload) => _save(payload, existing: existing),
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
          constraints: const BoxConstraints(maxWidth: 1000),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Location Groups',
                            style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary)),
                        SizedBox(height: 4),
                        Text('Group locations into accountable entities. Groups determine how stock '
                            'movements between your own locations are treated.',
                            style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                  if (canAdd && !offline)
                    ElevatedButton.icon(
                      onPressed: () => _openDialog(),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add Group'),
                    ),
                ],
              ),
              const SizedBox(height: 16),

              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.primary.withValues(alpha: 0.15)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline, size: 18, color: AppColors.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _interLocationModel == 'INTER_ENTITY'
                            ? 'Inter-Location Model: Independent Entities. Movements between different '
                                "groups post an inter-entity invoice using each group's accounts below."
                            : 'Inter-Location Model: Simple. All movements between locations are pure '
                                'stock transfers — no accounts are required for groups. '
                                'Change this in Company Setup.',
                        style: const TextStyle(fontSize: 13, color: AppColors.textPrimary),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              if (offline) const OfflineBanner(),
              if (offline) const SizedBox(height: 16),

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
                      const Icon(Icons.error_outline, color: AppColors.negative, size: 18),
                      const SizedBox(width: 10),
                      Expanded(child: Text(_error!, style: const TextStyle(fontSize: 13, color: AppColors.negative))),
                      TextButton(onPressed: _load, child: const Text('Retry')),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],

              Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
                                  Icon(Icons.account_tree_outlined, size: 40, color: AppColors.textSecondary),
                                  SizedBox(height: 12),
                                  Text('No location groups yet.', style: TextStyle(color: AppColors.textSecondary)),
                                  Text('Click "Add Group" to create one.',
                                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                                ],
                              ),
                            ),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildTableHeader(),
                              const Divider(height: 1),
                              ..._rows.asMap().entries.map((e) => _buildRow(e.value, e.key.isEven)),
                            ],
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: const Row(
        children: [
          SizedBox(width: 100, child: _HCol('Code')),
          SizedBox(width: 180, child: _HCol('Group Name')),
          SizedBox(width: 160, child: _HCol('Responsible')),
          SizedBox(width: 220, child: _HCol('Customer / Supplier A/c')),
          SizedBox(width: 80,  child: _HCol('Active')),
          SizedBox(width: 90,  child: _HCol('Actions')),
        ],
      ),
    );
  }

  Widget _buildRow(Map<String, dynamic> row, bool isEven) {
    final active      = row['is_active'] as bool? ?? true;
    final responsible = row['responsible'] as Map<String, dynamic>?;
    final custAcc     = row['customer_account'] as Map<String, dynamic>?;
    final suppAcc     = row['supplier_account'] as Map<String, dynamic>?;
    final offline     = ref.watch(sessionProvider)?.offlineMode ?? false;
    return Container(
      color: isEven ? Colors.transparent : AppColors.surfaceVariant.withValues(alpha: 0.35),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(width: 100, child: Text(row['group_code'] ?? '',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary))),
          SizedBox(width: 180, child: Text(row['group_name'] ?? '',
              style: const TextStyle(fontSize: 13, color: AppColors.textPrimary))),
          SizedBox(width: 160, child: Text(responsible?['full_name'] as String? ?? '—',
              style: const TextStyle(fontSize: 13, color: AppColors.textPrimary))),
          SizedBox(
            width: 220,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  custAcc != null ? '[${custAcc['account_code']}] ${custAcc['account_name']}' : '—',
                  style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                ),
                Text(
                  suppAcc != null ? '[${suppAcc['account_code']}] ${suppAcc['account_name']}' : '—',
                  style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          SizedBox(
            width: 80,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: (active ? AppColors.positive : AppColors.textDisabled).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(active ? 'Active' : 'Inactive',
                  style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600,
                      color: active ? AppColors.positive : AppColors.textSecondary)),
            ),
          ),
          SizedBox(
            width: 90,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined, size: 18, color: AppColors.primary),
                  onPressed: (canEdit && !offline) ? () => _openDialog(row) : null,
                ),
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.negative),
                  onPressed: (canEdit && !offline) ? () => _confirmDelete(row) : null,
                ),
              ],
            ),
          ),
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
            fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textSecondary, letterSpacing: 0.3));
  }
}

// ── Add / Edit Dialog ─────────────────────────────────────────────────────────

class _LocationGroupDialog extends ConsumerStatefulWidget {
  final Map<String, dynamic>? existing;
  final List<Map<String, dynamic>> users;
  final String interLocationModel;
  final void Function(Map<String, dynamic> payload) onSave;
  const _LocationGroupDialog({
    this.existing,
    required this.users,
    required this.interLocationModel,
    required this.onSave,
  });

  @override
  ConsumerState<_LocationGroupDialog> createState() => _LocationGroupDialogState();
}

class _LocationGroupDialogState extends ConsumerState<_LocationGroupDialog> {
  final _formKey     = GlobalKey<FormState>();
  final _codeCtrl     = TextEditingController();
  final _nameCtrl     = TextEditingController();

  String? _responsibleUserId;
  String? _customerAccountId;
  String? _supplierAccountId;
  bool    _isActive = true;
  bool    _saving   = false;

  bool get _isEdit => widget.existing != null;
  bool get _interEntity => widget.interLocationModel == 'INTER_ENTITY';

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
  void initState() {
    super.initState();
    final d = widget.existing;
    if (d != null) {
      _codeCtrl.text     = d['group_code'] ?? '';
      _nameCtrl.text     = d['group_name'] ?? '';
      _responsibleUserId = d['responsible_user_id'] as String?;
      _customerAccountId = d['customer_account_id'] as String?;
      _supplierAccountId = d['supplier_account_id'] as String?;
      _isActive          = d['is_active'] as bool? ?? true;
    }
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all required fields.'), backgroundColor: Colors.orange),
      );
      return;
    }
    setState(() => _saving = true);
    widget.onSave({
      'id':                  widget.existing?['id'] as String? ?? const Uuid().v4(),
      'group_code':          _codeCtrl.text.trim(),
      'group_name':          _nameCtrl.text.trim(),
      'responsible_user_id': _responsibleUserId,
      'customer_account_id': _interEntity ? _customerAccountId : null,
      'supplier_account_id': _interEntity ? _supplierAccountId : null,
      'is_active':           _isActive,
    });
  }

  String _displayAccount(Map<String, dynamic> a) => '[${a['account_code']}] ${a['account_name']}';

  Widget _buildAccountPicker({
    required String label,
    required List<Map<String, dynamic>> accounts,
    required String? selectedId,
    required ValueChanged<String?> onSelected,
  }) {
    final matches = accounts.where((a) => a['id'] == selectedId).toList();
    final selected = matches.isNotEmpty ? matches.first : null;
    return SizedBox(
      height: 56,
      child: Autocomplete<Map<String, dynamic>>(
        key: ValueKey(selectedId ?? 'none-$label'),
        initialValue: TextEditingValue(text: selected != null ? _displayAccount(selected) : ''),
        optionsBuilder: (v) {
          final q = v.text.toLowerCase().trim();
          final filtered = q.isEmpty
              ? accounts
              : accounts.where((a) =>
                  (a['account_code'] as String? ?? '').toLowerCase().contains(q) ||
                  (a['account_name']  as String? ?? '').toLowerCase().contains(q));
          return filtered.take(50);
        },
        displayStringForOption: _displayAccount,
        fieldViewBuilder: (context, textCtrl, focusNode, onFieldSubmitted) => TextFormField(
          controller: textCtrl,
          focusNode: focusNode,
          onChanged: (v) { if (v.isEmpty) onSelected(null); },
          decoration: InputDecoration(labelText: label, prefixIcon: const Icon(Icons.account_balance_outlined)),
          style: const TextStyle(fontSize: 13),
        ),
        onSelected: (a) => onSelected(a['id'] as String?),
        optionsViewBuilder: (context, onSel, options) => Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(4),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240, maxWidth: 460),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, idx) {
                  final a = options.elementAt(idx);
                  return InkWell(
                    onTap: () => onSel(a),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Text(_displayAccount(a), style: const TextStyle(fontSize: 13)),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accountsAsync = ref.watch(accountsProvider);
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(_isEdit ? Icons.edit_outlined : Icons.add_box_outlined,
                        color: AppColors.primary, size: 22),
                    const SizedBox(width: 10),
                    Text(_isEdit ? 'Edit Location Group' : 'Add Location Group',
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                    const Spacer(),
                    IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(context, rootNavigator: true).pop()),
                  ],
                ),
                const SizedBox(height: 20),

                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextFormField(
                        controller: _codeCtrl,
                        decoration: InputDecoration(
                          label: _req('Group Code'),
                          prefixIcon: const Icon(Icons.tag_outlined),
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Group code is required' : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 3,
                      child: TextFormField(
                        controller: _nameCtrl,
                        decoration: InputDecoration(
                          label: _req('Group Name'),
                          prefixIcon: const Icon(Icons.label_outline),
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Group name is required' : null,
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
                      .map((u) => DropdownMenuItem(value: u['id'] as String, child: Text(u['full_name'] as String)))
                      .toList(),
                  onChanged: (v) => setState(() => _responsibleUserId = v),
                ),
                const SizedBox(height: 14),

                if (_interEntity) ...[
                  const Text('Inter-entity accounts',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                  const SizedBox(height: 6),
                  accountsAsync.when(
                    data: (accounts) {
                      final customerAccs = accounts.where((a) => a['account_nature'] == 'Customer').toList();
                      final supplierAccs = accounts.where((a) => a['account_nature'] == 'Supplier').toList();
                      return Column(
                        children: [
                          _buildAccountPicker(
                            label: 'Customer Account (receivable)',
                            accounts: customerAccs,
                            selectedId: _customerAccountId,
                            onSelected: (id) => setState(() => _customerAccountId = id),
                          ),
                          const SizedBox(height: 14),
                          _buildAccountPicker(
                            label: 'Supplier Account (payable)',
                            accounts: supplierAccs,
                            selectedId: _supplierAccountId,
                            onSelected: (id) => setState(() => _supplierAccountId = id),
                          ),
                        ],
                      );
                    },
                    loading: () => const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                    error: (e, _) => Text('Could not load accounts: $e',
                        style: const TextStyle(fontSize: 12, color: AppColors.negative)),
                  ),
                  const SizedBox(height: 14),
                ],

                Column(
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Active', style: TextStyle(fontSize: 14)),
                      value: _isActive,
                      onChanged: (v) => setState(() => _isActive = v),
                      activeThumbColor: AppColors.positive,
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                        onPressed: _saving ? null : () => Navigator.of(context, rootNavigator: true).pop(),
                        child: const Text('Cancel')),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 140,
                      child: ElevatedButton(
                        onPressed: _saving ? null : _save,
                        child: _saving
                            ? const SizedBox(
                                height: 18, width: 18,
                                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                            : Text(_isEdit ? 'Save Changes' : 'Add Group'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
