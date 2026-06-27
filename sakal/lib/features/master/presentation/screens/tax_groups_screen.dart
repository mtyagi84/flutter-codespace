import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../data/datasources/tax_master_remote_ds.dart';
import '../../data/models/tax_group_member_model.dart';
import '../../data/models/tax_group_model.dart';
import '../../data/models/tax_model.dart';

class TaxGroupsScreen extends ConsumerStatefulWidget {
  const TaxGroupsScreen({super.key});
  @override
  ConsumerState<TaxGroupsScreen> createState() => _TaxGroupsScreenState();
}

class _TaxGroupsScreenState extends ConsumerState<TaxGroupsScreen>
    with ScreenPermissionMixin<TaxGroupsScreen> {
  @override String get screenName => 'tax_groups';

  List<TaxGroupModel>  _groups  = [];
  List<TaxModel>       _allTaxes = [];
  bool    _loading = true;
  bool    _saving  = false;
  String? _error;
  String  _search  = '';

  String          _panelMode = 'none';
  TaxGroupModel?  _editing;
  // Members for the group being edited
  List<TaxGroupMemberModel> _members = [];

  // Form
  final _formKey   = GlobalKey<FormState>();
  final _codeCtrl  = TextEditingController();
  final _nameCtrl  = TextEditingController();
  final _descCtrl  = TextEditingController();
  final _sortCtrl  = TextEditingController();
  String _selApplicable = 'BOTH';
  bool   _formActive    = true;

  late TaxMasterRemoteDs _ds;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ds = TaxMasterRemoteDs();
      _load();
    });
  }

  @override
  void dispose() {
    _codeCtrl.dispose(); _nameCtrl.dispose();
    _descCtrl.dispose(); _sortCtrl.dispose();
    super.dispose();
  }

  bool get _canAdd  => canAdd;
  bool get _canEdit => canEdit;

  // ── Load ────────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    final s = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        _ds.getTaxGroups(clientId: s.clientId, companyId: s.companyId),
        _ds.getTaxes(clientId: s.clientId, companyId: s.companyId),
      ]);
      _groups   = results[0] as List<TaxGroupModel>;
      _allTaxes = results[1] as List<TaxModel>;
    } catch (e) {
      setState(() => _error = 'Failed to load: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  TaxModel? _taxById(String id) =>
      _allTaxes.firstWhere((t) => t.id == id, orElse: () =>
          TaxModel(id: id, clientId: '', companyId: '', taxCode: '?', taxName: '?', taxTypeCode: 'VAT'));

  // ── Panel ────────────────────────────────────────────────────────────────────

  void _openAdd() {
    _editing      = null;
    _members      = [];
    _codeCtrl.clear();
    _nameCtrl.clear();
    _descCtrl.clear();
    _sortCtrl.text  = '0';
    _selApplicable  = 'BOTH';
    _formActive     = true;
    setState(() => _panelMode = 'add');
  }

  Future<void> _openEdit(TaxGroupModel group) async {
    _editing      = group;
    _codeCtrl.text  = group.groupCode;
    _nameCtrl.text  = group.groupName;
    _descCtrl.text  = group.description ?? '';
    _sortCtrl.text  = group.sortOrder.toString();
    _selApplicable  = group.applicableOn;
    _formActive     = group.isActive;
    setState(() { _panelMode = 'edit'; _members = []; });
    // Load members
    if (group.id != null) {
      try {
        final raw = await _ds.getMembersForGroup(group.id!);
        // Resolve display names from loaded taxes
        final s = ref.read(sessionProvider)!;
        _members = raw.map((m) {
          final t = _taxById(m.taxId);
          return m.withDisplay(code: t?.taxCode ?? '?', name: t?.taxName ?? '?');
        }).toList();
        setState(() {});
      } catch (_) {}
    }
  }

  void _closePanel() => setState(() => _panelMode = 'none');

  // ── Save ─────────────────────────────────────────────────────────────────────

  Future<void> _saveGroup() async {
    if (!_formKey.currentState!.validate()) return;
    final s = ref.read(sessionProvider)!;
    setState(() => _saving = true);
    try {
      final isEdit = _editing != null;
      final payload = {
        if (isEdit) 'id': _editing!.id,
        'client_id':    s.clientId,
        'company_id':   s.companyId,
        'group_code':   _codeCtrl.text.trim().toUpperCase(),
        'group_name':   _nameCtrl.text.trim(),
        'applicable_on': _selApplicable,
        if (_descCtrl.text.trim().isNotEmpty) 'description': _descCtrl.text.trim(),
        'sort_order':   int.tryParse(_sortCtrl.text) ?? 0,
        'is_active':    _formActive,
        'is_deleted':   false,
        'updated_by':   s.userId,
        'updated_at':   DateTime.now().toIso8601String(),
        if (!isEdit) 'created_by': s.userId,
      };
      await _ds.saveTaxGroup(payload);

      // For edit: save updated members via atomic RPC.
      // For add: we need the new group ID first — reload and find by code.
      String? groupId = _editing?.id;
      if (!isEdit) {
        final freshGroups = await _ds.getTaxGroups(clientId: s.clientId, companyId: s.companyId);
        final saved = freshGroups.firstWhere(
          (g) => g.groupCode == _codeCtrl.text.trim().toUpperCase(),
          orElse: () => freshGroups.first,
        );
        groupId = saved.id;
      }
      if (groupId != null && _members.isNotEmpty) {
        await _ds.replaceGroupMembers(
          groupId:   groupId,
          clientId:  s.clientId,
          companyId: s.companyId,
          members:   _members,
          userId:    s.userId,
        );
      }
      _closePanel();
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e'), backgroundColor: AppColors.negative));
      }
    } finally {
      setState(() => _saving = false);
    }
  }

  Future<void> _deleteGroup(TaxGroupModel group) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Tax Group?'),
        content: Text('Delete "${group.groupCode} — ${group.groupName}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.negative),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final s = ref.read(sessionProvider)!;
    await _ds.softDeleteTaxGroup(id: group.id!, userId: s.userId);
    if (_panelMode == 'edit' && _editing?.id == group.id) _closePanel();
    await _load();
  }

  // ── Members management ────────────────────────────────────────────────────────

  void _removeMember(int index) {
    setState(() {
      _members.removeAt(index);
      _renumber();
    });
  }

  void _renumber() {
    for (int i = 0; i < _members.length; i++) {
      _members[i] = _members[i].copyWith(sequenceNo: i + 1);
    }
  }

  Future<void> _showAddMemberSheet() async {
    final alreadyIds = _members.map((m) => m.taxId).toSet();
    final available  = _allTaxes
        .where((t) => t.id != null && !alreadyIds.contains(t.id) && t.isActive)
        .toList();
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No taxes available to add.')));
      return;
    }
    String filter = '';
    final selected = await showModalBottomSheet<TaxModel>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (_, setS) => SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.6,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Search taxes…', isDense: true,
                    prefixIcon: Icon(Icons.search)),
                onChanged: (v) => setS(() => filter = v.toLowerCase()),
              ),
            ),
            Expanded(
              child: ListView(
                children: available
                    .where((t) => filter.isEmpty
                        || t.taxCode.toLowerCase().contains(filter)
                        || t.taxName.toLowerCase().contains(filter))
                    .map((t) => ListTile(
                          dense: true,
                          title: Text('[${t.taxCode}] ${t.taxName}',
                              style: const TextStyle(fontSize: 13)),
                          subtitle: Text(t.taxTypeCode,
                              style: const TextStyle(fontSize: 11)),
                          onTap: () => Navigator.pop(ctx, t),
                        ))
                    .toList(),
              ),
            ),
          ]),
        ),
      ),
    );
    if (selected == null || selected.id == null) return;
    final s = ref.read(sessionProvider)!;
    setState(() {
      _members.add(TaxGroupMemberModel(
        clientId:   s.clientId,
        companyId:  s.companyId,
        taxGroupId: _editing?.id ?? '',
        taxId:      selected.id!,
        sequenceNo: _members.length + 1,
        taxCode:    selected.taxCode,
        taxName:    selected.taxName,
      ));
    });
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDesktop = Responsive.isDesktop(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Tax Groups'),
        backgroundColor: AppColors.surface,
        elevation: 0,
        actions: [
          if (_loading) const Padding(padding: EdgeInsets.all(12),
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load, tooltip: 'Refresh'),
        ],
      ),
      floatingActionButton: _canAdd ? FloatingActionButton.extended(
        onPressed: _openAdd,
        label: const Text('Add Group'),
        icon: const Icon(Icons.add),
        backgroundColor: AppColors.primary,
      ) : null,
      body: Column(children: [
        const OfflineBanner(),
        Expanded(child: isDesktop ? _desktopLayout() : _mobileLayout()),
      ]),
    );
  }

  Widget _desktopLayout() => Row(children: [
    SizedBox(width: 440, child: _listPanel()),
    const VerticalDivider(width: 1),
    Expanded(child: _panelMode == 'none' ? _emptyPanel() : _formPanel()),
  ]);

  Widget _mobileLayout() => _panelMode == 'none' ? _listPanel() : _formPanel();

  Widget _emptyPanel() => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.playlist_add_check, size: 64, color: AppColors.primary.withOpacity(0.3)),
      const SizedBox(height: 12),
      const Text('Select a tax group to edit, or tap Add Group'),
    ]),
  );

  // ── List Panel ────────────────────────────────────────────────────────────────

  Widget _listPanel() => Column(children: [
    Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        decoration: const InputDecoration(
          hintText: 'Search groups…',
          prefixIcon: Icon(Icons.search),
          isDense: true,
        ),
        onChanged: (v) => setState(() => _search = v.toLowerCase()),
      ),
    ),
    if (_error != null) Padding(
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        Expanded(child: Text(_error!, style: const TextStyle(color: AppColors.negative))),
        TextButton(onPressed: _load, child: const Text('Retry')),
      ]),
    ),
    Expanded(child: _loading
        ? const Center(child: CircularProgressIndicator())
        : _buildList()),
  ]);

  Widget _buildList() {
    final filtered = _groups.where((g) {
      if (_search.isEmpty) return true;
      return g.groupCode.toLowerCase().contains(_search) ||
             g.groupName.toLowerCase().contains(_search);
    }).toList();

    if (filtered.isEmpty) {
      return Center(child: Text(_search.isEmpty ? 'No tax groups configured.' : 'No results.'));
    }

    return ListView.builder(
      itemCount: filtered.length,
      itemBuilder: (ctx, i) {
        final g = filtered[i];
        final selected = _editing?.id == g.id && _panelMode == 'edit';
        return ListTile(
          selected: selected,
          selectedTileColor: AppColors.primary.withOpacity(0.08),
          leading: CircleAvatar(
            radius: 18,
            backgroundColor: g.isActive ? AppColors.secondary : Colors.grey.shade300,
            child: Text(g.groupCode.substring(0, g.groupCode.length > 2 ? 2 : g.groupCode.length),
              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
          ),
          title: Text(g.groupName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          subtitle: Row(children: [
            Text('${g.applicableOn}  ', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
            if (!g.isActive) Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(color: Colors.orange.shade100, borderRadius: BorderRadius.circular(4)),
              child: const Text('Inactive', style: TextStyle(fontSize: 10, color: Colors.deepOrange)),
            ),
          ]),
          trailing: PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'edit') _openEdit(g);
              if (v == 'delete') _deleteGroup(g);
            },
            itemBuilder: (_) => [
              if (_canEdit) const PopupMenuItem(value: 'edit', child: Text('Edit')),
              const PopupMenuItem(value: 'delete',
                  child: Text('Delete', style: TextStyle(color: AppColors.negative))),
            ],
          ),
          onTap: _canEdit ? () => _openEdit(g) : null,
        );
      },
    );
  }

  // ── Form Panel ────────────────────────────────────────────────────────────────

  Widget _formPanel() {
    final isEdit = _panelMode == 'edit';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Form(
        key: _formKey,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Header
          Row(children: [
            Expanded(child: Text(isEdit ? 'Edit Tax Group' : 'New Tax Group',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
            if (Responsive.isMobile(context))
              IconButton(icon: const Icon(Icons.close), onPressed: _closePanel),
          ]),
          const SizedBox(height: 20),

          // Code + Name
          Row(children: [
            SizedBox(width: 160,
              child: TextFormField(
                controller: _codeCtrl,
                textCapitalization: TextCapitalization.characters,
                enabled: !isEdit,
                decoration: const InputDecoration(labelText: 'Group Code *'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: TextFormField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: 'Group Name *'),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
            )),
          ]),
          const SizedBox(height: 14),

          // Applicable On
          Text('Applicable On', style: TextStyle(color: Colors.grey.shade700, fontSize: 12)),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'SALES',    label: Text('Sales')),
              ButtonSegment(value: 'PURCHASE', label: Text('Purchase')),
              ButtonSegment(value: 'BOTH',     label: Text('Both')),
            ],
            selected: {_selApplicable},
            onSelectionChanged: (s) => setState(() => _selApplicable = s.first),
          ),
          const SizedBox(height: 14),

          // Description
          TextFormField(
            controller: _descCtrl,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Description'),
          ),
          const SizedBox(height: 14),

          // Sort + Active
          Row(children: [
            SizedBox(width: 100,
              child: TextFormField(
                controller: _sortCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Sort Order'),
              ),
            ),
            const SizedBox(width: 20),
            SwitchListTile.adaptive(
              dense: true,
              title: const Text('Active'),
              value: _formActive,
              onChanged: (v) => setState(() => _formActive = v),
              contentPadding: EdgeInsets.zero,
            ),
          ]),
          const SizedBox(height: 24),

          // Save / Cancel
          Row(children: [
            FilledButton(
              onPressed: _saving ? null : _saveGroup,
              style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
              child: _saving
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text(isEdit ? 'Update Group' : 'Save Group'),
            ),
            const SizedBox(width: 12),
            TextButton(onPressed: _closePanel, child: const Text('Cancel')),
          ]),

          // Members section
          const SizedBox(height: 28),
          _membersSection(),
        ]),
      ),
    );
  }

  // ── Members Section ────────────────────────────────────────────────────────────

  Widget _membersSection() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [
        const Text('Tax Members', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const Spacer(),
        if (_canEdit) TextButton.icon(
          onPressed: _showAddMemberSheet,
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add Tax'),
        ),
      ]),
      Text('Drag to reorder. Compound taxes must appear after their source taxes.',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
      const SizedBox(height: 10),
      if (_members.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Text('No members yet. Add taxes to this group.'),
        ),
      if (_members.isNotEmpty) ReorderableListView(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        onReorder: (oldIndex, newIndex) {
          setState(() {
            if (newIndex > oldIndex) newIndex -= 1;
            final item = _members.removeAt(oldIndex);
            _members.insert(newIndex, item);
            _renumber();
          });
        },
        children: [
          for (int i = 0; i < _members.length; i++)
            _memberTile(_members[i], i),
        ],
      ),
    ],
  );

  Widget _memberTile(TaxGroupMemberModel m, int index) {
    final tax = _taxById(m.taxId);
    return Card(
      key: ValueKey(m.taxId),
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        dense: true,
        leading: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.drag_handle, color: Colors.grey),
          const SizedBox(width: 8),
          CircleAvatar(
            radius: 12,
            backgroundColor: AppColors.primary.withOpacity(0.12),
            child: Text('${m.sequenceNo}',
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.primary)),
          ),
        ]),
        title: Text(m.taxCode.isNotEmpty ? '[${m.taxCode}] ${m.taxName}'
            : '[${tax?.taxCode ?? '?'}] ${tax?.taxName ?? '?'}',
            style: const TextStyle(fontSize: 13)),
        subtitle: Text(tax?.taxTypeCode ?? '', style: const TextStyle(fontSize: 11)),
        trailing: _canEdit ? IconButton(
          icon: const Icon(Icons.close, size: 18),
          color: AppColors.negative,
          onPressed: () => _removeMember(index),
        ) : null,
      ),
    );
  }
}
