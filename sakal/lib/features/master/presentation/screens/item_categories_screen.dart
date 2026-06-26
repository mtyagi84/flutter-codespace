import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';
import '../../data/models/category_level_model.dart';
import '../../data/models/item_category_model.dart';
import '../../data/models/product_flag_type_model.dart';
import '../../domain/repositories/item_categories_repository.dart';
import '../providers/item_categories_providers.dart';

class ItemCategoriesScreen extends ConsumerStatefulWidget {
  const ItemCategoriesScreen({super.key});

  @override
  ConsumerState<ItemCategoriesScreen> createState() => _ItemCategoriesScreenState();
}

class _ItemCategoriesScreenState extends ConsumerState<ItemCategoriesScreen> {
  // Data
  List<CategoryLevelModel>               _levels     = [];
  List<ProductFlagTypeModel>             _flagTypes  = [];
  List<ItemCategoryModel>                _flat       = [];
  List<ItemCategoryModel>                _roots      = [];
  Map<String, List<ItemCategoryModel>>   _childMap   = {};
  bool    _loading = true;
  bool    _saving  = false;
  String? _error;

  // Tree state
  final Set<String> _expanded = {};

  // Panel state: 'none' | 'add' | 'edit'
  String              _panelMode = 'none';
  ItemCategoryModel?  _editNode;

  // Form
  final _nameCtrl  = TextEditingController();
  final _shortCtrl = TextEditingController();
  final _sortCtrl  = TextEditingController();
  final _formKey   = GlobalKey<FormState>();
  int?                _formLevel;
  String?             _formParentId;
  bool                _formActive = true;
  Map<String, bool>   _formFlags  = {};   // flag_key → current toggle value

  late ItemCategoriesRepository _repo;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _repo = ref.read(itemCategoriesRepositoryProvider);
      _load();
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _shortCtrl.dispose();
    _sortCtrl.dispose();
    super.dispose();
  }

  // ── Permission helper ───────────────────────────────────────────────────────
  Map<String, dynamic>? _findFeature() {
    final menus = ref.read(menuProvider);
    for (final m in menus) {
      for (final g in m.groups) {
        for (final item in g.features) {
          if (item.screenName == 'item_categories') return {
            'can_add':  item.addAllowed,
            'can_edit': item.editAllowed,
          };
        }
      }
    }
    return null;
  }

  bool get _canAdd  => (_findFeature()?['can_add']  as bool?) ?? true;
  bool get _canEdit => (_findFeature()?['can_edit'] as bool?) ?? true;

  // ── Data ────────────────────────────────────────────────────────────────────
  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        _repo.getLevels(clientId: session.clientId, companyId: session.companyId),
        _repo.getFlagTypes(clientId: session.clientId, companyId: session.companyId),
        _repo.getCategories(clientId: session.clientId, companyId: session.companyId),
      ]);
      final levels    = results[0] as List<CategoryLevelModel>;
      final flagTypes = results[1] as List<ProductFlagTypeModel>;
      final cats      = results[2] as List<ItemCategoryModel>;
      _buildTree(levels, flagTypes, cats);
    } catch (e) {
      setState(() => _error = 'Failed to load: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  void _buildTree(List<CategoryLevelModel> levels,
      List<ProductFlagTypeModel> flagTypes, List<ItemCategoryModel> cats) {
    _levels    = levels;
    _flagTypes = flagTypes;
    _flat      = cats;
    _roots    = cats.where((c) => c.parentId == null).toList();
    _childMap = {};
    for (final cat in cats) {
      if (cat.parentId != null) {
        _childMap.putIfAbsent(cat.parentId!, () => []).add(cat);
      }
    }
  }

  String _levelLabel(int levelNo) {
    final found = _levels.where((l) => l.levelNo == levelNo).firstOrNull;
    return found?.levelLabel ?? 'Level $levelNo';
  }

  int get _maxLevel => _levels.isEmpty ? 4 : _levels.map((l) => l.levelNo).reduce((a,b) => a > b ? a : b);

  // ── Panel ───────────────────────────────────────────────────────────────────
  // Build flags map: use parent/node flags if set, else fall back to flag type default
  Map<String, bool> _initFlags({Map<String, bool>? inherit}) {
    return {
      for (final ft in _flagTypes)
        ft.flagKey: inherit?.containsKey(ft.flagKey) == true
            ? inherit![ft.flagKey]!
            : ft.defaultValue,
    };
  }

  void _openAdd({ItemCategoryModel? parent}) {
    _editNode     = null;
    _nameCtrl.clear();
    _shortCtrl.clear();
    _sortCtrl.text = '0';
    _formActive   = true;
    _formParentId = parent?.id;
    _formLevel    = parent == null ? 1 : (parent.levelNo + 1);
    _formFlags    = _initFlags(inherit: parent?.flags);
    setState(() => _panelMode = 'add');
  }

  void _openEdit(ItemCategoryModel node) {
    _editNode       = node;
    _nameCtrl.text  = node.categoryName;
    _shortCtrl.text = node.categoryShort ?? '';
    _sortCtrl.text  = node.sortOrder.toString();
    _formActive     = node.isActive;
    _formLevel      = node.levelNo;
    _formParentId   = node.parentId;
    _formFlags      = _initFlags(inherit: node.flags);
    setState(() => _panelMode = 'edit');
  }

  void _closePanel() => setState(() => _panelMode = 'none');

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_formLevel == null) return;

    final session      = ref.read(sessionProvider)!;
    final isEdit       = _editNode != null;
    final oldFlags     = _editNode?.flags ?? {};
    final flagsChanged = isEdit && !_mapsEqual(oldFlags, _formFlags);

    setState(() => _saving = true);
    try {
      final payload = {
        if (_editNode?.id != null) 'id': _editNode!.id,
        'client_id':     session.clientId,
        'company_id':    session.companyId,
        if (_formParentId != null) 'parent_id': _formParentId,
        'level_no':      _formLevel,
        'category_name': _nameCtrl.text.trim(),
        if (_shortCtrl.text.trim().isNotEmpty) 'category_short': _shortCtrl.text.trim(),
        'flags':         _formFlags,
        'sort_order':    int.tryParse(_sortCtrl.text) ?? 0,
        'is_active':     _formActive,
        'is_deleted':    false,
        'updated_by':    session.userId,
        'updated_at':    DateTime.now().toIso8601String(),
        if (!isEdit) 'created_by': session.userId,
      };
      await _repo.saveCategory(payload);

      // Cascade flags to sub-categories if flags changed on an existing node
      if (flagsChanged && _editNode?.id != null) {
        final childIds = _getSubtreeIds(_editNode!.id!, excludeRoot: true);
        if (childIds.isNotEmpty) {
          final cascade = await _showCascadeDialog(childIds.length);
          if (cascade == true) {
            await _repo.cascadeFlagsToChildren(
              childIds: childIds,
              flags:    _formFlags,
              userId:   session.userId,
            );
          }
        }
      }

      _closePanel();
      await _load();
    } catch (e) {
      _showMsg('Save failed: $e');
    } finally {
      setState(() => _saving = false);
    }
  }

  // Collect all descendant IDs from the in-memory tree
  List<String> _getSubtreeIds(String rootId, {bool excludeRoot = false}) {
    final result = <String>[];
    final queue  = [rootId];
    while (queue.isNotEmpty) {
      final id  = queue.removeAt(0);
      if (!excludeRoot || id != rootId) result.add(id);
      queue.addAll((_childMap[id] ?? []).map((c) => c.id!));
    }
    return result;
  }

  bool _mapsEqual(Map<String, bool> a, Map<String, bool> b) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (b[k] != a[k]) return false;
    }
    return true;
  }

  Future<bool?> _showCascadeDialog(int count) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Apply to Sub-Categories?'),
        content: Text(
            'You changed the flags on this category.\n\n'
            'Apply the same flags to all $count sub-categories underneath?\n\n'
            'Choosing "No" only updates this category — children keep their own settings.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('No — this category only'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Yes — update all $count sub-categories'),
          ),
        ],
      ),
    );
  }

  Future<void> _delete(ItemCategoryModel node) async {
    final hasKids = await _repo.hasChildren(node.id!);
    if (hasKids) {
      _showMsg('Cannot delete "${node.categoryName}" — it has sub-categories. Delete those first.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Category?'),
        content: Text('Remove "${node.categoryName}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.negative),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _saving = true);
    try {
      await _repo.softDeleteCategory(
        id: node.id!,
        userId: ref.read(sessionProvider)!.userId,
      );
      if (_editNode?.id == node.id) _closePanel();
      await _load();
    } catch (e) {
      _showMsg('Delete failed: $e');
    } finally {
      setState(() => _saving = false);
    }
  }

  void _showMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── Build ───────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final isWide = Responsive.isDesktop(context);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        style: const TextStyle(color: AppColors.negative, fontSize: 13)),
                  ],
                  if (_levels.isEmpty) ...[
                    const SizedBox(height: 32),
                    _buildNoLevelsCard(),
                  ] else ...[
                    const SizedBox(height: 20),
                    Expanded(
                      child: isWide
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(width: 320, child: _buildTree()),
                                if (_panelMode != 'none') ...[
                                  const SizedBox(width: 16),
                                  Expanded(child: _buildFormPanel()),
                                ],
                              ],
                            )
                          : _panelMode == 'none'
                              ? _buildTree()
                              : _buildFormPanel(),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Item Categories',
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary)),
              const SizedBox(height: 4),
              Text(
                '${_flat.length} categories  ·  ${_levels.length} levels configured',
                style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
        if (_saving)
          const Padding(
            padding: EdgeInsets.only(right: 12),
            child: SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        if (_canAdd && _levels.isNotEmpty)
          FilledButton.icon(
            onPressed: _saving ? null : () => _openAdd(),
            icon: const Icon(Icons.add, size: 18),
            label: Text('Add ${_levelLabel(1)}'),
          ),
      ],
    );
  }

  Widget _buildNoLevelsCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.account_tree_outlined, size: 40, color: AppColors.textDisabled),
          SizedBox(height: 12),
          Text('No category levels configured.',
              style: TextStyle(
                  fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          SizedBox(height: 4),
          Text('Go to Setup → Category Level Setup to define your hierarchy first.',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              textAlign: TextAlign.center),
        ],
      ),
    );
  }

  // ── Tree ────────────────────────────────────────────────────────────────────
  Widget _buildTree() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: _roots.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('No categories yet. Click "Add" to start.',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                    textAlign: TextAlign.center),
              ),
            )
          : ListView.builder(
              itemCount: _roots.length,
              itemBuilder: (_, i) => _buildNode(_roots[i], 0),
            ),
    );
  }

  Widget _buildNode(ItemCategoryModel node, int depth) {
    final children = _childMap[node.id] ?? [];
    final hasKids  = children.isNotEmpty;
    final expanded = _expanded.contains(node.id);
    final isSelected = _editNode?.id == node.id;
    final canGoDeeper = node.levelNo < _maxLevel;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: _canEdit ? () => _openEdit(node) : null,
          child: Container(
            color: isSelected
                ? AppColors.primary.withOpacity(0.07)
                : Colors.transparent,
            padding: EdgeInsets.only(
              left: 12.0 + depth * 20.0,
              right: 8,
              top: 6,
              bottom: 6,
            ),
            child: Row(
              children: [
                // Expand/collapse toggle
                if (hasKids)
                  GestureDetector(
                    onTap: () => setState(() {
                      if (expanded) _expanded.remove(node.id!);
                      else _expanded.add(node.id!);
                    }),
                    child: Icon(
                      expanded ? Icons.expand_more : Icons.chevron_right,
                      size: 18,
                      color: AppColors.textSecondary,
                    ),
                  )
                else
                  const SizedBox(width: 18),
                const SizedBox(width: 4),
                // Level chip
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: _levelColor(node.levelNo).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'L${node.levelNo}',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: _levelColor(node.levelNo)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    node.categoryName,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                      color: node.isActive ? AppColors.textPrimary : AppColors.textSecondary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Add child button
                if (_canAdd && canGoDeeper)
                  Tooltip(
                    message: 'Add ${_levelLabel(node.levelNo + 1)}',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: _saving ? null : () => _openAdd(parent: node),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.add, size: 16, color: AppColors.textSecondary),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (expanded)
          ...children.map((child) => _buildNode(child, depth + 1)),
      ],
    );
  }

  Color _levelColor(int levelNo) {
    const colors = [
      AppColors.primary,
      AppColors.secondary,
      Color(0xFF2E7D32),
      Color(0xFF6A1B9A),
    ];
    return colors[(levelNo - 1).clamp(0, 3)];
  }

  // ── Form Panel ──────────────────────────────────────────────────────────────
  Widget _buildFormPanel() {
    final isEdit = _panelMode == 'edit';

    // Parent options for the selected level
    final parentLevel = (_formLevel ?? 1) - 1;
    final parentOptions = parentLevel > 0
        ? _flat.where((c) => c.levelNo == parentLevel).toList()
        : <ItemCategoryModel>[];

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Panel header
          Container(
            padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.border)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    isEdit
                        ? 'Edit ${_levelLabel(_formLevel ?? 1)}'
                        : 'New ${_levelLabel(_formLevel ?? 1)}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                        color: AppColors.textPrimary),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: _closePanel,
                ),
              ],
            ),
          ),

          // Form body
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Level selector (only for Add; locked on Edit)
                    if (!isEdit) ...[
                      DropdownButtonFormField<int>(
                        value: _formLevel,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Level'),
                        items: _levels.map((l) => DropdownMenuItem(
                          value: l.levelNo,
                          child: Text('${l.levelNo} — ${l.levelLabel}'),
                        )).toList(),
                        onChanged: (v) => setState(() {
                          _formLevel    = v;
                          _formParentId = null;
                        }),
                        validator: (v) => v == null ? 'Select a level' : null,
                      ),
                      const SizedBox(height: 16),
                    ] else ...[
                      // Show level as read-only chip
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Row(
                          children: [
                            const Text('Level: ',
                                style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                              decoration: BoxDecoration(
                                color: _levelColor(_formLevel ?? 1).withOpacity(0.12),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'L$_formLevel — ${_levelLabel(_formLevel ?? 1)}',
                                style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: _levelColor(_formLevel ?? 1),
                                    fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    // Parent selector (hidden for Level 1)
                    if ((_formLevel ?? 1) > 1) ...[
                      DropdownButtonFormField<String>(
                        value: _formParentId,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: 'Parent ${_levelLabel((_formLevel ?? 2) - 1)}',
                        ),
                        hint: const Text('Select parent…'),
                        items: parentOptions.map((p) => DropdownMenuItem(
                          value: p.id,
                          child: Text(p.categoryName, overflow: TextOverflow.ellipsis),
                        )).toList(),
                        onChanged: (v) => setState(() => _formParentId = v),
                        validator: (v) => v == null ? 'Parent is required' : null,
                      ),
                      const SizedBox(height: 16),
                    ],

                    // Name
                    TextFormField(
                      controller: _nameCtrl,
                      decoration: const InputDecoration(labelText: 'Name *'),
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? 'Name is required' : null,
                    ),
                    const SizedBox(height: 16),

                    // Short name
                    TextFormField(
                      controller: _shortCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Short Name',
                        hintText: 'Optional abbreviation',
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Sort order
                    TextFormField(
                      controller: _sortCtrl,
                      decoration: const InputDecoration(labelText: 'Sort Order'),
                      keyboardType: TextInputType.number,
                      validator: (v) =>
                          (v != null && v.isNotEmpty && int.tryParse(v) == null)
                              ? 'Must be a number' : null,
                    ),
                    const SizedBox(height: 16),

                    // Is Active
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Active'),
                      subtitle: const Text('Inactive categories are hidden on product forms'),
                      value: _formActive,
                      onChanged: (v) => setState(() => _formActive = v),
                    ),

                    // Dynamic flags
                    if (_flagTypes.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const Divider(),
                      const SizedBox(height: 4),
                      const Text('Transaction Flags',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textSecondary,
                              letterSpacing: 0.5)),
                      const SizedBox(height: 4),
                      ..._flagTypes.where((f) => f.isActive).map((ft) =>
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: Text(ft.flagLabel,
                              style: const TextStyle(fontSize: 13)),
                          value: _formFlags[ft.flagKey] ?? ft.defaultValue,
                          onChanged: (v) => setState(
                              () => _formFlags[ft.flagKey] = v),
                        ),
                      ),
                    ],

                    const SizedBox(height: 24),

                    // Action buttons
                    Row(
                      children: [
                        if (isEdit && _canEdit)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                  foregroundColor: AppColors.negative,
                                  side: const BorderSide(color: AppColors.negative)),
                              onPressed: _saving ? null : () => _delete(_editNode!),
                              icon: const Icon(Icons.delete_outline, size: 16),
                              label: const Text('Delete'),
                            ),
                          ),
                        const Spacer(),
                        TextButton(
                          onPressed: _saving ? null : _closePanel,
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _saving ? null : _save,
                          child: _saving
                              ? const SizedBox(
                                  width: 16, height: 16,
                                  child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2))
                              : Text(isEdit ? 'Update' : 'Save'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
