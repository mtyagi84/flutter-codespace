import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../domain/repositories/department_consumption_area_repository.dart';
import '../providers/department_consumption_area_providers.dart';

class _LinkRow {
  String? id; // null = not yet saved
  String? consumptionAreaId;
  String? accountId;
  String accountDisplay;
  bool deleted = false;

  _LinkRow({this.id, this.consumptionAreaId, this.accountId, this.accountDisplay = ''});
}

class DepartmentConsumptionAreaScreen extends ConsumerStatefulWidget {
  const DepartmentConsumptionAreaScreen({super.key});

  @override
  ConsumerState<DepartmentConsumptionAreaScreen> createState() => _DepartmentConsumptionAreaScreenState();
}

class _DepartmentConsumptionAreaScreenState extends ConsumerState<DepartmentConsumptionAreaScreen>
    with ScreenPermissionMixin<DepartmentConsumptionAreaScreen> {
  @override String get screenName => RouteNames.departmentConsumptionAreas;

  DepartmentConsumptionAreaRepository get _ds => ref.read(departmentConsumptionAreaRepositoryProvider);

  List<Map<String, dynamic>> _departments = [];
  List<Map<String, dynamic>> _consumptionAreas = [];
  Set<String> _linkedAreaIds = {};
  String? _selectedDepartmentId;
  final List<_LinkRow> _rows = [];

  bool _loading = true;
  bool _loadingRows = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      final departments = await _ds.getDepartments(clientId: session.clientId, companyId: session.companyId);
      final areas        = await _ds.getConsumptionAreas(clientId: session.clientId, companyId: session.companyId);
      final linked        = await _ds.getAllLinkedAreaIds(clientId: session.clientId, companyId: session.companyId);
      if (!mounted) return;
      setState(() {
        _departments = departments;
        _consumptionAreas = areas;
        _linkedAreaIds = linked;
        _selectedDepartmentId = departments.isNotEmpty ? departments.first['id'] as String : null;
        _loading = false;
      });
      if (_selectedDepartmentId != null) await _loadRows();
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load: $e'; });
    }
  }

  Future<void> _loadRows() async {
    if (_selectedDepartmentId == null) return;
    final session = ref.read(sessionProvider)!;
    setState(() { _loadingRows = true; _rows.clear(); });
    try {
      final rows = await _ds.getLinksForDepartment(
        clientId: session.clientId, companyId: session.companyId, departmentId: _selectedDepartmentId!,
      );
      if (!mounted) return;
      setState(() {
        _rows.addAll(rows.map((r) {
          final area    = r['area'] as Map<String, dynamic>?;
          final account = r['account'] as Map<String, dynamic>?;
          return _LinkRow(
            id: r['id'] as String,
            consumptionAreaId: r['consumption_area_id'] as String,
            accountId: r['account_id'] as String,
            accountDisplay: account != null ? '[${account['account_code']}] ${account['account_name']}' : '',
          );
        }));
        _loadingRows = false;
      });
    } catch (e) {
      if (mounted) { setState(() => _loadingRows = false); _showSnack('Could not load links: $e', color: AppColors.negative); }
    }
  }

  void _onDepartmentChanged(String? id) {
    if (id == null || id == _selectedDepartmentId) return;
    setState(() => _selectedDepartmentId = id);
    _loadRows();
  }

  void _addRow() => setState(() => _rows.add(_LinkRow()));

  void _removeRow(_LinkRow row) {
    if (row.id == null) {
      setState(() => _rows.remove(row));
    } else {
      setState(() => row.deleted = true);
    }
  }

  List<Map<String, dynamic>> _areaOptionsFor(_LinkRow row) => _consumptionAreas
      .where((a) => !_linkedAreaIds.contains(a['id']) || a['id'] == row.consumptionAreaId)
      .toList();

  Future<void> _saveAll() async {
    final session = ref.read(sessionProvider)!;
    for (final row in _rows) {
      if (row.deleted) continue;
      if (row.consumptionAreaId == null || row.accountId == null) {
        _showSnack('Every row needs a Consumption Area and an Account.', color: AppColors.negative);
        return;
      }
    }

    setState(() { _saving = true; _error = null; });
    try {
      for (final row in _rows.where((r) => r.deleted && r.id != null)) {
        await _ds.deleteLink(id: row.id!, userId: session.userId);
      }
      for (final row in _rows.where((r) => !r.deleted)) {
        await _ds.saveLink(payload: {
          if (row.id != null) 'id': row.id,
          'client_id':           session.clientId,
          'company_id':          session.companyId,
          'department_id':       _selectedDepartmentId,
          'consumption_area_id': row.consumptionAreaId,
          'account_id':          row.accountId,
          'created_by':          session.userId,
          'updated_by':          session.userId,
        });
      }
      if (mounted) {
        _showSnack('Consumption areas saved.', color: AppColors.positive);
        setState(() => _saving = false);
      }
      final linked = await _ds.getAllLinkedAreaIds(clientId: session.clientId, companyId: session.companyId);
      if (mounted) setState(() => _linkedAreaIds = linked);
      await _loadRows();
    } catch (e) {
      if (mounted) setState(() { _saving = false; _error = 'Save failed: $e'; });
    }
  }

  void _showSnack(String msg, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  @override
  Widget build(BuildContext context) {
    final session   = ref.watch(sessionProvider);
    final isOffline = session?.offlineMode ?? false;
    final isMobile  = Responsive.isMobile(context);
    final canEdit   = !isOffline && canAdd;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isOffline) const OfflineBanner(),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Consumption Area Setup', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
                SizedBox(height: 2),
                Text('Link each Consumption Area to one Department and one expense account',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              ]),
            ),
            if (canEdit && !_loading) FilledButton(
              onPressed: _saving ? null : _saveAll,
              child: _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Save'),
            ),
          ]),
        ),
        const Divider(height: 20),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : isOffline
                  ? const Center(child: Text('This screen needs a live connection.', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)))
                  : SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (_error != null) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                              color: AppColors.negative.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppColors.negative.withValues(alpha: 0.3)),
                            ),
                            child: Text(_error!, style: const TextStyle(fontSize: 13, color: AppColors.negative)),
                          ),
                          const SizedBox(height: 16),
                        ],
                        if (_departments.isEmpty)
                          const Text('No departments found — add "Department" values via Common Masters first.',
                              style: TextStyle(fontSize: 13, color: AppColors.textSecondary))
                        else ...[
                          SizedBox(
                            width: isMobile ? double.infinity : 320,
                            child: DropdownButtonFormField<String>(
                              decoration: const InputDecoration(labelText: 'Department', border: OutlineInputBorder(),
                                  isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                              isExpanded: true,
                              isDense: true,
                              itemHeight: null,
                              initialValue: _selectedDepartmentId,
                              items: _departments.map((d) => DropdownMenuItem(
                                  value: d['id'] as String,
                                  child: Text(d['description'] as String, overflow: TextOverflow.ellipsis))).toList(),
                              onChanged: _onDepartmentChanged,
                            ),
                          ),
                          const SizedBox(height: 20),
                          if (_loadingRows)
                            const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator()))
                          else ...[
                            ..._rows.where((r) => !r.deleted).map((row) => _buildRow(row, canEdit)),
                            if (canEdit) Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: TextButton.icon(
                                onPressed: _addRow,
                                icon: const Icon(Icons.add, size: 16),
                                label: const Text('Add Consumption Area'),
                              ),
                            ),
                          ],
                        ],
                      ]),
                    ),
        ),
      ],
    );
  }

  Widget _buildRow(_LinkRow row, bool canEdit) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10));
    final accountsAsync = ref.watch(accountsProvider);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        elevation: 0,
        color: AppColors.background,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<String>(
                decoration: dec.copyWith(labelText: 'Consumption Area'),
                isExpanded: true,
                isDense: true,
                itemHeight: null,
                initialValue: row.consumptionAreaId,
                items: _areaOptionsFor(row).map((a) => DropdownMenuItem(
                    value: a['id'] as String,
                    child: Text(a['description'] as String, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))).toList(),
                onChanged: (!canEdit || row.id != null) ? null : (v) => setState(() => row.consumptionAreaId = v),
              ),
            ),
            SizedBox(
              width: 280,
              child: accountsAsync.when(
                data: (accounts) => Autocomplete<Map<String, dynamic>>(
                  key: ValueKey('${row.hashCode}-${row.accountDisplay}'),
                  initialValue: TextEditingValue(text: row.accountDisplay),
                  displayStringForOption: (a) => '[${a['account_code']}] ${a['account_name']}',
                  optionsBuilder: (v) {
                    if (!canEdit) return const [];
                    final q = v.text.toLowerCase().trim();
                    return q.isEmpty ? accounts : accounts.where((a) =>
                        (a['account_code'] as String? ?? '').toLowerCase().contains(q) ||
                        (a['account_name'] as String? ?? '').toLowerCase().contains(q));
                  },
                  onSelected: (a) => setState(() {
                    row.accountId = a['id'] as String;
                    row.accountDisplay = '[${a['account_code']}] ${a['account_name']}';
                  }),
                  fieldViewBuilder: (context, textCtrl, focusNode, onFieldSubmitted) => TextFormField(
                    controller: textCtrl, focusNode: focusNode, enabled: canEdit,
                    decoration: dec.copyWith(labelText: 'Expense Account'),
                    style: const TextStyle(fontSize: 13),
                  ),
                  optionsViewBuilder: (context, onSel, opts) => Align(
                    alignment: Alignment.topLeft,
                    child: Material(
                      elevation: 4,
                      borderRadius: BorderRadius.circular(4),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 260, minWidth: 260),
                        child: ListView.builder(
                          padding: EdgeInsets.zero,
                          shrinkWrap: true,
                          itemCount: opts.length,
                          itemBuilder: (context, idx) {
                            final a = opts.elementAt(idx);
                            final parentRaw = a['parent'];
                            final parent = parentRaw is Map<String, dynamic> ? parentRaw : null;
                            return InkWell(
                              onTap: () => onSel(a),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text('[${a['account_code']}] ${a['account_name']}', style: const TextStyle(fontSize: 13)),
                                  if (parent?['account_name'] != null)
                                    Text(parent!['account_name'] as String, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                                ]),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
                loading: () => const SizedBox(height: 48, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
                error: (e, _) => Text('Could not load accounts: $e'),
              ),
            ),
            if (canEdit) IconButton(
              icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.negative),
              onPressed: () => _removeRow(row),
            ),
          ]),
        ),
      ),
    );
  }
}
