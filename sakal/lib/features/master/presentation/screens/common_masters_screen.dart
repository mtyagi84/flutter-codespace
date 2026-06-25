import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/models/menu_models.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../data/models/common_master_model.dart';
import '../../data/models/common_master_type_model.dart';
import '../providers/common_masters_providers.dart';

MenuFeature? _findFeature(List<MenuModule> modules, String screenPath) {
  for (final mod in modules) {
    for (final grp in mod.groups) {
      for (final feat in grp.features) {
        if (feat.screenName == screenPath) return feat;
      }
    }
  }
  return null;
}

// ── Inline edit state for a single row ────────────────────────────────────────

class _EditState {
  final TextEditingController descCtrl;
  final TextEditingController shortNameCtrl;
  final TextEditingController sortOrderCtrl;
  bool isActive;

  _EditState({
    String desc      = '',
    String shortName = '',
    String sortOrder = '0',
    bool   isActive  = true,
  })  : descCtrl      = TextEditingController(text: desc),
        shortNameCtrl = TextEditingController(text: shortName),
        sortOrderCtrl = TextEditingController(text: sortOrder),
        isActive      = isActive;

  void dispose() {
    descCtrl.dispose();
    shortNameCtrl.dispose();
    sortOrderCtrl.dispose();
  }

  bool get isValid => descCtrl.text.trim().isNotEmpty;
}

// ── Screen ─────────────────────────────────────────────────────────────────────

class CommonMastersScreen extends ConsumerStatefulWidget {
  const CommonMastersScreen({super.key});

  @override
  ConsumerState<CommonMastersScreen> createState() =>
      _CommonMastersScreenState();
}

class _CommonMastersScreenState extends ConsumerState<CommonMastersScreen> {
  List<CommonMasterTypeModel> _types   = [];
  List<CommonMasterModel>     _masters = [];

  String? _selectedTypeId;
  String  _search       = '';
  int     _offset       = 0;
  bool    _hasMore      = true;
  static const _pageSize = 50;

  bool    _loadingTypes   = true;
  bool    _loadingMasters = false;
  String? _error;
  bool    _saving = false;

  // Inline add row state (null = not adding)
  _EditState? _addState;

  // Inline edit: map from master id → edit state
  final Map<String, _EditState> _editStates = {};

  final _searchDebounce = ValueNotifier<String>('');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadTypes());
  }

  @override
  void dispose() {
    _addState?.dispose();
    for (final s in _editStates.values) s.dispose();
    _searchDebounce.dispose();
    super.dispose();
  }

  // ── Load master types ──────────────────────────────────────────────────────

  Future<void> _loadTypes() async {
    setState(() { _loadingTypes = true; _error = null; });
    try {
      final types = await ref.read(commonMastersRepositoryProvider).getTypes();
      if (!mounted) return;
      setState(() {
        _types         = types;
        _loadingTypes  = false;
        _selectedTypeId = types.isNotEmpty ? types.first.id : null;
      });
      if (_selectedTypeId != null) await _loadMasters(reset: true);
    } catch (e) {
      if (mounted) setState(() { _loadingTypes = false; _error = 'Could not load types: $e'; });
    }
  }

  // ── Load masters for selected type ────────────────────────────────────────

  Future<void> _loadMasters({bool reset = false}) async {
    if (_selectedTypeId == null) return;
    final session = ref.read(sessionProvider)!;

    if (reset) {
      setState(() { _offset = 0; _hasMore = true; _masters = []; });
    }

    setState(() { _loadingMasters = true; _error = null; });
    try {
      final results = await ref.read(commonMastersRepositoryProvider).getMasters(
        clientId:  session.clientId,
        companyId: session.companyId,
        typeId:    _selectedTypeId!,
        search:    _search.isEmpty ? null : _search,
        limit:     _pageSize,
        offset:    _offset,
      );
      if (!mounted) return;
      setState(() {
        if (reset) {
          _masters = results;
        } else {
          _masters = [..._masters, ...results];
        }
        _hasMore        = results.length == _pageSize;
        _offset         = _masters.length;
        _loadingMasters = false;
      });
    } catch (e) {
      if (mounted) setState(() { _loadingMasters = false; _error = 'Could not load data: $e'; });
    }
  }

  // ── Search debounce ────────────────────────────────────────────────────────

  void _onSearchChanged(String value) {
    _search = value;
    Future.delayed(const Duration(milliseconds: 300), () {
      if (_search == value && mounted) _loadMasters(reset: true);
    });
  }

  // ── Save (add or edit) ─────────────────────────────────────────────────────

  Future<void> _saveNew() async {
    if (_addState == null || !_addState!.isValid) return;
    final session = ref.read(sessionProvider)!;
    setState(() { _saving = true; });
    try {
      final saved = await ref.read(commonMastersRepositoryProvider).saveMaster({
        'client_id':   session.clientId,
        'company_id':  session.companyId,
        'type_id':     _selectedTypeId,
        'description': _addState!.descCtrl.text.trim(),
        if (_addState!.shortNameCtrl.text.trim().isNotEmpty)
          'short_name': _addState!.shortNameCtrl.text.trim(),
        'sort_order':  int.tryParse(_addState!.sortOrderCtrl.text) ?? 0,
        'is_active':   _addState!.isActive,
        'created_by':  session.userId,
        'updated_by':  session.userId,
      });
      _addState!.dispose();
      setState(() {
        _addState = null;
        _masters  = [saved, ..._masters];
        _saving   = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Record saved.'),
          backgroundColor: AppColors.positive,
        ));
      }
    } catch (e) {
      if (mounted) setState(() { _saving = false; });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Save failed: $e'),
          backgroundColor: AppColors.negative,
        ));
      }
    }
  }

  Future<void> _saveEdit(CommonMasterModel master) async {
    final state = _editStates[master.id];
    if (state == null || !state.isValid) return;
    final session = ref.read(sessionProvider)!;
    setState(() { _saving = true; });
    try {
      final saved = await ref.read(commonMastersRepositoryProvider).saveMaster({
        'id':          master.id,
        'client_id':   master.clientId,
        'company_id':  master.companyId,
        'type_id':     master.typeId,
        'description': state.descCtrl.text.trim(),
        'short_name':  state.shortNameCtrl.text.trim().isEmpty
            ? null
            : state.shortNameCtrl.text.trim(),
        'sort_order':  int.tryParse(state.sortOrderCtrl.text) ?? 0,
        'is_active':   state.isActive,
        'updated_by':  session.userId,
        'updated_at':  DateTime.now().toIso8601String(),
      });
      state.dispose();
      setState(() {
        _editStates.remove(master.id);
        final idx = _masters.indexWhere((m) => m.id == master.id);
        if (idx != -1) _masters[idx] = saved;
        _saving = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Record updated.'),
          backgroundColor: AppColors.positive,
        ));
      }
    } catch (e) {
      if (mounted) setState(() { _saving = false; });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Save failed: $e'),
          backgroundColor: AppColors.negative,
        ));
      }
    }
  }

  void _cancelEdit(String masterId) {
    _editStates[masterId]?.dispose();
    setState(() => _editStates.remove(masterId));
  }

  void _cancelAdd() {
    _addState?.dispose();
    setState(() => _addState = null);
  }

  void _startAdd() {
    _addState?.dispose();
    setState(() => _addState = _EditState());
  }

  void _startEdit(CommonMasterModel m) {
    _editStates[m.id]?.dispose();
    setState(() {
      _editStates[m.id] = _EditState(
        desc:      m.description,
        shortName: m.shortName ?? '',
        sortOrder: m.sortOrder.toString(),
        isActive:  m.isActive,
      );
    });
  }

  // ── Selected type name ─────────────────────────────────────────────────────

  String get _selectedTypeName {
    if (_selectedTypeId == null) return 'Master';
    return _types.firstWhere((t) => t.id == _selectedTypeId,
        orElse: () => CommonMasterTypeModel(
            id: '', typeKey: '', typeName: 'Master', isActive: true)).typeName;
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final session   = ref.watch(sessionProvider);
    final isOffline = session?.offlineMode ?? false;
    final isMobile  = Responsive.isMobile(context);

    final menus   = ref.watch(menuProvider);
    final feature = _findFeature(menus, RouteNames.commonMasters);

    if (feature == null) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline, size: 48, color: Color(0xFFADB5BD)),
            SizedBox(height: 12),
            Text('You do not have access to this screen.',
                style: TextStyle(color: Color(0xFF6B7280))),
          ],
        ),
      );
    }

    final canAdd  = feature.addAllowed  && !isOffline;
    final canEdit = feature.editAllowed && !isOffline;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isOffline) const OfflineBanner(),

        // ── Page header ────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Common Masters',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700,
                    color: AppColors.primary)),
            const SizedBox(height: 2),
            const Text('Shared lookup values used in Product and Item screens',
                style: TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
          ]),
        ),

        const Divider(height: 24),

        // ── Type selector + search + add button ───────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: isMobile
              ? _buildControlsMobile(canAdd)
              : _buildControlsDesktop(canAdd),
        ),

        const SizedBox(height: 12),

        // ── Error banner ──────────────────────────────────────────────────
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.negative.withOpacity(0.08),
                border: Border.all(color: AppColors.negative.withOpacity(0.3)),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(children: [
                const Icon(Icons.error_outline, color: AppColors.negative, size: 16),
                const SizedBox(width: 8),
                Expanded(child: Text(_error!,
                    style: const TextStyle(color: AppColors.negative, fontSize: 13))),
                TextButton(
                  onPressed: () => _loadMasters(reset: true),
                  child: const Text('Retry'),
                ),
              ]),
            ),
          ),

        // ── Content ────────────────────────────────────────────────────────
        Expanded(
          child: _loadingTypes || (_loadingMasters && _masters.isEmpty)
              ? const Center(child: CircularProgressIndicator())
              : _masters.isEmpty && _addState == null
                  ? _buildEmpty(canAdd)
                  : isMobile
                      ? _buildMobileList(canEdit)
                      : _buildDesktopTable(canEdit),
        ),
      ],
    );
  }

  // ── Controls ──────────────────────────────────────────────────────────────

  Widget _buildControlsDesktop(bool canAdd) {
    return Row(
      children: [
        SizedBox(
          width: 220,
          child: _typeDropdown(),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 240,
          child: _searchField(),
        ),
        const Spacer(),
        if (canAdd)
          FilledButton.icon(
            icon: const Icon(Icons.add, size: 16),
            label: Text('Add $_selectedTypeName'),
            onPressed: _addState != null ? null : _startAdd,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              minimumSize: const Size(0, 40),
            ),
          ),
      ],
    );
  }

  Widget _buildControlsMobile(bool canAdd) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _typeDropdown(),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: _searchField()),
          if (canAdd) ...[
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _addState != null ? null : _startAdd,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                minimumSize: const Size(48, 40),
                padding: EdgeInsets.zero,
              ),
              child: const Icon(Icons.add, size: 18),
            ),
          ],
        ]),
      ],
    );
  }

  Widget _typeDropdown() {
    return DropdownButtonFormField<String>(
      decoration: const InputDecoration(
        labelText: 'Master Type',
        border: OutlineInputBorder(),
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      value: _selectedTypeId,
      items: _types
          .map((t) => DropdownMenuItem(value: t.id, child: Text(t.typeName)))
          .toList(),
      onChanged: (v) {
        if (v == null || v == _selectedTypeId) return;
        _cancelAdd();
        for (final id in _editStates.keys.toList()) _cancelEdit(id);
        setState(() => _selectedTypeId = v);
        _loadMasters(reset: true);
      },
    );
  }

  Widget _searchField() {
    return TextFormField(
      decoration: const InputDecoration(
        hintText: 'Search...',
        prefixIcon: Icon(Icons.search, size: 18),
        border: OutlineInputBorder(),
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      onChanged: _onSearchChanged,
    );
  }

  // ── Empty state ────────────────────────────────────────────────────────────

  Widget _buildEmpty(bool canAdd) {
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.list_alt_outlined, size: 52, color: Color(0xFFADB5BD)),
        const SizedBox(height: 14),
        Text(
          'No $_selectedTypeName records found.',
          style: const TextStyle(color: Color(0xFF6B7280), fontSize: 14),
        ),
        if (canAdd) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.add, size: 16),
            label: Text('Add $_selectedTypeName'),
            onPressed: _startAdd,
          ),
        ],
      ]),
    );
  }

  // ── Desktop table ──────────────────────────────────────────────────────────

  Widget _buildDesktopTable(bool canEdit) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      child: Column(children: [
        // Header row
        Container(
          decoration: const BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
          ),
          child: Row(children: [
            _colHdr('Description',  flex: 4),
            _colHdr('Short Name',   flex: 2),
            _colHdr('Sort Order',   flex: 2),
            _colHdr('Active',       flex: 1),
            _colHdr('',             flex: 2),
          ]),
        ),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade200),
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
          ),
          child: Column(children: [
            // Inline add row
            if (_addState != null) ...[
              _buildDesktopEditRow(
                state:    _addState!,
                onSave:   _saveNew,
                onCancel: _cancelAdd,
                isNew:    true,
              ),
              Divider(height: 1, color: Colors.grey.shade200),
            ],

            // Existing rows
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _masters.length,
              separatorBuilder: (_, __) =>
                  Divider(height: 1, color: Colors.grey.shade200),
              itemBuilder: (_, i) {
                final m = _masters[i];
                final editState = _editStates[m.id];
                return editState != null
                    ? _buildDesktopEditRow(
                        state:    editState,
                        onSave:   () => _saveEdit(m),
                        onCancel: () => _cancelEdit(m.id),
                        isNew:    false,
                      )
                    : _buildDesktopReadRow(m, canEdit);
              },
            ),

            // Load more
            if (_hasMore && !_loadingMasters)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: TextButton(
                  onPressed: _loadMasters,
                  child: const Text('Load more'),
                ),
              ),
            if (_loadingMasters && _masters.isNotEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: CircularProgressIndicator(),
              ),
          ]),
        ),
      ]),
    );
  }

  Widget _colHdr(String label, {int flex = 1}) => Expanded(
        flex: flex,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Text(label,
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 13)),
        ),
      );

  Widget _buildDesktopReadRow(CommonMasterModel m, bool canEdit) {
    return Container(
      color: Colors.white,
      child: Row(children: [
        Expanded(
          flex: 4,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(m.description,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          ),
        ),
        Expanded(
          flex: 2,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: m.shortName != null
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(m.shortName!,
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.primary,
                            fontWeight: FontWeight.w600)),
                  )
                : const Text('—',
                    style: TextStyle(color: Color(0xFFADB5BD), fontSize: 13)),
          ),
        ),
        Expanded(
          flex: 2,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text('${m.sortOrder}',
                style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
          ),
        ),
        Expanded(
          flex: 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Icon(
              m.isActive ? Icons.check_circle_outline : Icons.cancel_outlined,
              size: 18,
              color: m.isActive ? AppColors.positive : AppColors.negative,
            ),
          ),
        ),
        Expanded(
          flex: 2,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: canEdit
                ? TextButton.icon(
                    icon: const Icon(Icons.edit_outlined, size: 14),
                    label: const Text('Edit'),
                    onPressed: () => _startEdit(m),
                    style: TextButton.styleFrom(
                        minimumSize: const Size(60, 36)),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ]),
    );
  }

  Widget _buildDesktopEditRow({
    required _EditState state,
    required VoidCallback onSave,
    required VoidCallback onCancel,
    required bool isNew,
  }) {
    return StatefulBuilder(
      builder: (_, setRowState) => Container(
        color: AppColors.primary.withOpacity(0.04),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(children: [
          // Description
          Expanded(
            flex: 4,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: TextFormField(
                controller: state.descCtrl,
                decoration: const InputDecoration(
                  labelText: 'Description *',
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
                onChanged: (_) => setRowState(() {}),
              ),
            ),
          ),
          // Short Name
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: TextFormField(
                controller: state.shortNameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Short Name',
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
              ),
            ),
          ),
          // Sort Order
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: TextFormField(
                controller: state.sortOrderCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Order',
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
              ),
            ),
          ),
          // Active
          Expanded(
            flex: 1,
            child: Checkbox(
              value: state.isActive,
              onChanged: (v) => setRowState(() => state.isActive = v ?? true),
              activeColor: AppColors.primary,
            ),
          ),
          // Save / Cancel
          Expanded(
            flex: 2,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              FilledButton(
                onPressed: _saving || !state.isValid ? null : onSave,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  minimumSize: const Size(56, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Save', style: TextStyle(fontSize: 13)),
              ),
              const SizedBox(width: 4),
              TextButton(
                onPressed: _saving ? null : onCancel,
                style: TextButton.styleFrom(
                    minimumSize: const Size(48, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 8)),
                child: const Text('Cancel'),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  // ── Mobile cards ────────────────────────────────────────────────────────────

  Widget _buildMobileList(bool canEdit) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: _masters.length +
          (_addState != null ? 1 : 0) +
          (_hasMore ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        int idx = i;

        // Inline add card at top
        if (_addState != null) {
          if (idx == 0) return _buildMobileEditCard(_addState!, _saveNew, _cancelAdd, true);
          idx--;
        }

        // Load more button
        if (idx == _masters.length) {
          return _hasMore
              ? Center(
                  child: TextButton(
                    onPressed: _loadMasters,
                    child: const Text('Load more'),
                  ),
                )
              : const SizedBox.shrink();
        }

        final m = _masters[idx];
        final editState = _editStates[m.id];
        return editState != null
            ? _buildMobileEditCard(
                editState, () => _saveEdit(m), () => _cancelEdit(m.id), false)
            : _buildMobileReadCard(m, canEdit);
      },
    );
  }

  Widget _buildMobileReadCard(CommonMasterModel m, bool canEdit) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(m.description,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                          color: AppColors.primary)),
                ),
                if (m.shortName != null)
                  Container(
                    margin: const EdgeInsets.only(left: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(m.shortName!,
                        style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.primary,
                            fontWeight: FontWeight.w600)),
                  ),
              ]),
              const SizedBox(height: 4),
              Row(children: [
                Text('Order: ${m.sortOrder}',
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF6B7280))),
                const SizedBox(width: 12),
                Icon(
                  m.isActive ? Icons.check_circle_outline : Icons.cancel_outlined,
                  size: 14,
                  color: m.isActive ? AppColors.positive : AppColors.negative,
                ),
                const SizedBox(width: 4),
                Text(
                  m.isActive ? 'Active' : 'Inactive',
                  style: TextStyle(
                    fontSize: 12,
                    color: m.isActive ? AppColors.positive : AppColors.negative,
                  ),
                ),
              ]),
            ]),
          ),
          if (canEdit)
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18),
              color: AppColors.primary,
              tooltip: 'Edit',
              onPressed: () => _startEdit(m),
            ),
        ]),
      ),
    );
  }

  Widget _buildMobileEditCard(
    _EditState state,
    VoidCallback onSave,
    VoidCallback onCancel,
    bool isNew,
  ) {
    return StatefulBuilder(
      builder: (_, setRowState) => Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: AppColors.primary.withOpacity(0.4), width: 1.5),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(children: [
            TextFormField(
              controller: state.descCtrl,
              decoration: const InputDecoration(
                labelText: 'Description *',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setRowState(() {}),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: TextFormField(
                  controller: state.shortNameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Short Name',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 90,
                child: TextFormField(
                  controller: state.sortOrderCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Order',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Checkbox(
                value: state.isActive,
                onChanged: (v) => setRowState(() => state.isActive = v ?? true),
                activeColor: AppColors.primary,
              ),
              const Text('Active', style: TextStyle(fontSize: 14)),
              const Spacer(),
              TextButton(
                onPressed: _saving ? null : onCancel,
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _saving || !state.isValid ? null : onSave,
                style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary),
                child: _saving
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Save'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
