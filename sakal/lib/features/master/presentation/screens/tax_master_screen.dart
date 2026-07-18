import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_presets.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/sakal_autocomplete.dart';
import '../../../../core/widgets/sakal_field_card.dart';
import '../../../../core/widgets/sakal_field_row.dart';
import '../../data/datasources/tax_master_remote_ds.dart';
import '../../data/models/tax_model.dart';
import '../../data/models/tax_rate_model.dart';
import '../../data/models/tax_type_model.dart';
class TaxMasterScreen extends ConsumerStatefulWidget {
  const TaxMasterScreen({super.key});
  @override
  ConsumerState<TaxMasterScreen> createState() => _TaxMasterScreenState();
}

class _TaxMasterScreenState extends ConsumerState<TaxMasterScreen>
    with ScreenPermissionMixin<TaxMasterScreen> {
  @override String get screenName => '/master/tax-master';

  // Data
  List<TaxTypeModel>         _taxTypes    = [];
  List<TaxModel>             _taxes       = [];
  List<TaxRateModel>         _allRates    = [];
  List<Map<String, String>>  _accounts    = [];  // id, code, name
  bool    _loading = true;
  bool    _saving  = false;
  String? _error;
  String  _search  = '';

  // Panel
  String     _panelMode = 'none';
  TaxModel?  _editing;

  // Form controllers
  final _formKey      = GlobalKey<FormState>();
  final _codeCtrl     = TextEditingController();
  final _nameCtrl     = TextEditingController();
  final _sortCtrl     = TextEditingController();
  String  _selTypeCode    = 'VAT';
  String  _selApplicable  = 'BOTH';
  String  _selCalcType    = 'PERCENTAGE';
  bool    _formInclusive  = false;
  bool    _formReverse    = false;
  bool    _formActive     = true;
  // GL account picker selections
  String? _outAccountId;
  String? _inAccountId;
  String? _expAccountId;
  // Compound sources (only when calculationType = COMPOUND)
  List<String> _compoundSourceIds = [];
  // Inline rate form
  bool     _showRateForm  = false;
  TaxRateModel? _editingRate;
  final _rateCtrl        = TextEditingController();
  final _rateFromCtrl    = TextEditingController();
  final _rateToCtrl      = TextEditingController();
  String  _rateLabel     = 'STANDARD';
  bool    _rateActive    = true;

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
    _codeCtrl.dispose(); _nameCtrl.dispose(); _sortCtrl.dispose();
    _rateCtrl.dispose(); _rateFromCtrl.dispose(); _rateToCtrl.dispose();
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
        _ds.getTaxTypes(),
        _ds.getTaxes(clientId: s.clientId, companyId: s.companyId),
        _ds.getAllRates(clientId: s.clientId, companyId: s.companyId),
        _ds.getPostingAccounts(clientId: s.clientId, companyId: s.companyId),
      ]);
      _taxTypes = results[0] as List<TaxTypeModel>;
      _taxes    = results[1] as List<TaxModel>;
      _allRates = results[2] as List<TaxRateModel>;
      _accounts = results[3] as List<Map<String, String>>;
    } catch (e) {
      setState(() => _error = 'Failed to load: $e');
    } finally {
      setState(() => _loading = false);
      logPermissions();
    }
  }

  List<TaxRateModel> _ratesFor(String taxId) =>
      _allRates.where((r) => r.taxId == taxId).toList();

  String _stdRateLabel(String taxId) {
    final r = _allRates
        .where((r) => r.taxId == taxId && r.rateLabel == 'STANDARD' && r.isCurrent)
        .toList()
      ..sort((a, b) => b.effectiveFrom.compareTo(a.effectiveFrom));
    if (r.isEmpty) return '—';
    return '${r.first.rate.toStringAsFixed(r.first.rate.truncateToDouble() == r.first.rate ? 0 : 2)}%';
  }

  String _typeName(String code) =>
      _taxTypes.firstWhere((t) => t.taxTypeCode == code,
          orElse: () => TaxTypeModel(id:'',taxTypeCode:code,typeName:code,isWithholding:false,sortOrder:0,isActive:true)).typeName;

  // ── Panel ────────────────────────────────────────────────────────────────────

  void _openAdd() {
    _editing           = null;
    _codeCtrl.clear();
    _nameCtrl.clear();
    _sortCtrl.text     = '0';
    _selTypeCode       = _taxTypes.isNotEmpty ? _taxTypes.first.taxTypeCode : '';
    _selApplicable     = 'BOTH';
    _selCalcType       = 'PERCENTAGE';
    _formInclusive     = false;
    _formReverse       = false;
    _formActive        = true;
    _outAccountId      = null;
    _inAccountId       = null;
    _expAccountId      = null;
    _compoundSourceIds = [];
    _showRateForm      = false;
    _editingRate       = null;
    setState(() => _panelMode = 'add');
  }

  void _openEdit(TaxModel tax) async {
    _editing           = tax;
    _codeCtrl.text     = tax.taxCode;
    _nameCtrl.text     = tax.taxName;
    _sortCtrl.text     = tax.sortOrder.toString();
    _selTypeCode       = tax.taxTypeCode;
    _selApplicable     = tax.applicableOn;
    _selCalcType       = tax.calculationType;
    _formInclusive     = tax.isPriceInclusive;
    _formReverse       = tax.isReverseCharge;
    _formActive        = tax.isActive;
    _outAccountId      = tax.glOutputAccountId;
    _inAccountId       = tax.glInputAccountId;
    _expAccountId      = tax.glExpenseAccountId;
    _showRateForm      = false;
    _editingRate       = null;
    if (tax.calculationType == 'COMPOUND' && tax.id != null) {
      try {
        _compoundSourceIds = await _ds.getCompoundSourceIds(tax.id!);
      } catch (_) {
        _compoundSourceIds = [];
      }
    } else {
      _compoundSourceIds = [];
    }
    setState(() => _panelMode = 'edit');
  }

  void _closePanel() => setState(() { _panelMode = 'none'; _showRateForm = false; });

  // ── Save / Delete ────────────────────────────────────────────────────────────

  Future<void> _saveTax() async {
    if (!_formKey.currentState!.validate()) return;
    final s = ref.read(sessionProvider)!;
    setState(() => _saving = true);
    try {
      final isEdit = _editing != null;
      final payload = {
        if (isEdit) 'id': _editing!.id,
        'client_id':        s.clientId,
        'company_id':       s.companyId,
        'tax_code':         _codeCtrl.text.trim().toUpperCase(),
        'tax_name':         _nameCtrl.text.trim(),
        'tax_type_code':    _selTypeCode,
        'applicable_on':    _selApplicable,
        'calculation_type': _selCalcType,
        'is_price_inclusive': _formInclusive,
        'is_reverse_charge':  _formReverse,
        if (_outAccountId != null) 'gl_output_account_id':  _outAccountId,
        if (_inAccountId  != null) 'gl_input_account_id':   _inAccountId,
        if (_expAccountId != null) 'gl_expense_account_id': _expAccountId,
        'sort_order':  int.tryParse(_sortCtrl.text) ?? 0,
        'is_active':   _formActive,
        'is_deleted':  false,
        'updated_by':  s.userId,
        'updated_at':  DateTime.now().toIso8601String(),
        if (!isEdit) 'created_by': s.userId,
      };
      await _ds.saveTax(payload);
      // Replace compound sources if COMPOUND type
      if (_selCalcType == 'COMPOUND') {
        // Need the new ID — reload and find by code
        final freshTaxes = await _ds.getTaxes(clientId: s.clientId, companyId: s.companyId);
        final saved = freshTaxes.firstWhere(
          (t) => t.taxCode == _codeCtrl.text.trim().toUpperCase(), orElse: () => freshTaxes.first);
        if (saved.id != null && _compoundSourceIds.isNotEmpty) {
          await _ds.replaceCompoundSources(
            compoundTaxId: saved.id!,
            clientId:  s.clientId,
            companyId: s.companyId,
            sourceTaxIds: _compoundSourceIds,
            userId: s.userId,
          );
        }
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

  Future<void> _deleteTax(TaxModel tax) async {
    if (tax.id == null) return;
    final usageCount = await _ds.countGroupsUsingTax(tax.id!);
    if (usageCount > 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Cannot delete — used in $usageCount tax group(s). Remove from groups first.'),
          backgroundColor: AppColors.negative));
      }
      return;
    }
    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Tax?'),
        content: Text('Delete "${tax.taxCode} — ${tax.taxName}"?'),
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
    await _ds.softDeleteTax(id: tax.id!, userId: s.userId);
    if (_panelMode == 'edit' && _editing?.id == tax.id) _closePanel();
    await _load();
  }

  // ── Rate form helpers ────────────────────────────────────────────────────────

  void _openAddRate() {
    _editingRate      = null;
    _rateCtrl.clear();
    _rateFromCtrl.text = DateTime.now().toIso8601String().substring(0, 10);
    _rateToCtrl.clear();
    _rateLabel = 'STANDARD';
    _rateActive = true;
    setState(() => _showRateForm = true);
  }

  void _openEditRate(TaxRateModel r) {
    _editingRate      = r;
    _rateCtrl.text    = r.rate.toString();
    _rateFromCtrl.text = r.effectiveFrom.toIso8601String().substring(0, 10);
    _rateToCtrl.text  = r.effectiveTo != null
        ? r.effectiveTo!.toIso8601String().substring(0, 10) : '';
    _rateLabel  = r.rateLabel;
    _rateActive = r.isActive;
    setState(() => _showRateForm = true);
  }

  Future<void> _saveRate() async {
    if (_editing?.id == null) return;
    final s = ref.read(sessionProvider)!;
    final rate = double.tryParse(_rateCtrl.text);
    if (rate == null) return;
    final from = DateTime.tryParse(_rateFromCtrl.text);
    if (from == null) return;
    final to = _rateToCtrl.text.isNotEmpty ? DateTime.tryParse(_rateToCtrl.text) : null;
    if (to != null && !to.isAfter(from)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Effective To must be after Effective From')));
      return;
    }
    setState(() => _saving = true);
    try {
      final payload = {
        if (_editingRate?.id != null) 'id': _editingRate!.id,
        'client_id':      s.clientId,
        'company_id':     s.companyId,
        'tax_id':         _editing!.id,
        'rate_label':     _rateLabel,
        'rate':           rate,
        'effective_from': _rateFromCtrl.text,
        if (to != null) 'effective_to': _rateToCtrl.text,
        'is_active':  _rateActive,
        'updated_by': s.userId,
        'updated_at': DateTime.now().toIso8601String(),
        if (_editingRate == null) 'created_by': s.userId,
      };
      await _ds.saveRate(payload);
      setState(() { _showRateForm = false; _editingRate = null; });
      // Reload just the rates
      final rates = await _ds.getAllRates(clientId: s.clientId, companyId: s.companyId);
      setState(() => _allRates = rates);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e'), backgroundColor: AppColors.negative));
      }
    } finally {
      setState(() => _saving = false);
    }
  }

  // ── Account picker ──────────────────────────────────────────────────────────

  // Account Picker convention app-wide: [code] name, search code OR name,
  // SakalAutocomplete (not a raw Autocomplete) for Up/Down/Enter keyboard
  // navigation -- same widget Sales Invoice's Customer picker uses.
  Widget _accountPicker({
    required String? selectedId,
    required ValueChanged<String?> onSelected,
  }) {
    final initial = selectedId != null
        ? _accounts.firstWhere((a) => a['id'] == selectedId, orElse: () => {'id':'','code':'','name':''})
        : null;
    final initialText = initial != null && initial['id']!.isNotEmpty
        ? '[${initial['code']}] ${initial['name']}' : '';

    return SakalAutocomplete<Map<String, String>>(
      key: ValueKey(selectedId),
      initialValue: TextEditingValue(text: initialText),
      displayStringForOption: (a) => '[${a['code']}] ${a['name']}',
      optionsBuilder: (v) {
        final q = v.text.toLowerCase();
        if (q.isEmpty) return _accounts;
        return _accounts.where((a) =>
            a['code']!.toLowerCase().contains(q) ||
            a['name']!.toLowerCase().contains(q));
      },
      onSelected: (a) => onSelected(a['id']),
      decoration: SakalFieldCard.bareDecoration,
      style: SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider)),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  // Same isMobile-only split-panel convention as the converted Customer/
  // Supplier Master screens — AppShell already supplies Scaffold/TopBar/
  // OfflineBanner, so this screen only ever returns its own content (the
  // screen used to wrap itself in its own Scaffold+AppBar, duplicating
  // TopBar's own title bar — removed as part of this conversion).
  @override
  Widget build(BuildContext context) {
    if (Responsive.isMobile(context)) {
      return _panelMode == 'none' ? _listPanel() : _formPanel();
    }
    return Row(children: [
      SizedBox(width: 440, child: _listPanel()),
      const VerticalDivider(width: 1, thickness: 1, color: AppColors.border),
      Expanded(child: _panelMode == 'none' ? _emptyPanel() : _formPanel()),
    ]);
  }

  Widget _emptyPanel() => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.receipt_long_outlined, size: 64, color: AppColors.primary.withValues(alpha: 0.3)),
      const SizedBox(height: 12),
      const Text('Select a tax to edit, or tap Add Tax'),
    ]),
  );

  // ── List Panel ───────────────────────────────────────────────────────────────

  Widget _listPanel() {
    final offline = ref.watch(sessionProvider)?.offlineMode ?? false;
    return Column(children: [
    Container(
      color: AppColors.surface,
      padding: const EdgeInsets.all(16),
      child: Row(children: [
        const Expanded(child: Text('Taxes',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
                color: AppColors.textPrimary))),
        if (_loading)
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: _load, tooltip: 'Refresh'),
        if (_canAdd && !offline)
          FilledButton.icon(
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add'),
            onPressed: _openAdd,
          ),
      ]),
    ),
    Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: SakalFieldCard(
        label: 'Search',
        editable: true,
        child: TextField(
          style: SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider)),
          decoration: SakalFieldCard.bareDecoration.copyWith(
            hintText: 'Search by code or name…',
            hintStyle: const TextStyle(fontSize: 12, color: AppColors.textDisabled, fontWeight: FontWeight.normal),
            prefixIcon: const Icon(Icons.search, size: 16),
          ),
          onChanged: (v) => setState(() => _search = v.toLowerCase()),
        ),
      ),
    ),
    const Divider(height: 1, color: AppColors.border),
    if (_error != null) Padding(
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        Expanded(child: Text(_error!, style: const TextStyle(color: AppColors.negative))),
        TextButton(onPressed: _load, child: const Text('Retry')),
      ]),
    ),
    Expanded(child: _loading ? const Center(child: CircularProgressIndicator())
        : _buildList()),
  ]);
  }

  Widget _buildList() {
    final offline = ref.watch(sessionProvider)?.offlineMode ?? false;
    final filtered = _taxes.where((t) {
      if (_search.isEmpty) return true;
      return t.taxCode.toLowerCase().contains(_search) ||
             t.taxName.toLowerCase().contains(_search) ||
             t.taxTypeCode.toLowerCase().contains(_search);
    }).toList();

    if (filtered.isEmpty) {
      return Center(child: Text(_search.isEmpty ? 'No taxes configured.' : 'No results.'));
    }

    return ListView.builder(
      itemCount: filtered.length,
      itemBuilder: (ctx, i) {
        final tax = filtered[i];
        final selected = _editing?.id == tax.id && _panelMode == 'edit';
        final stdRate  = _stdRateLabel(tax.id ?? '');
        return ListTile(
          selected: selected,
          selectedTileColor: ThemePresetConfig.all[ref.watch(themePresetProvider)]!.accent.withValues(alpha: 0.15),
          tileColor: tax.isActive ? null : const Color(0xFFF9FAFB),
          leading: CircleAvatar(
            radius: 18,
            backgroundColor: tax.isActive ? AppColors.primary : Colors.grey.shade300,
            child: Text(tax.taxCode.substring(0, tax.taxCode.length > 2 ? 2 : tax.taxCode.length),
              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
          ),
          title: Text(tax.taxName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          subtitle: Text('${_typeName(tax.taxTypeCode)} · ${tax.applicableOn}  $stdRate',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          trailing: PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'edit') _openEdit(tax);
              if (v == 'delete') _deleteTax(tax);
            },
            itemBuilder: (_) => [
              if (_canEdit && !offline) const PopupMenuItem(value: 'edit', child: Text('Edit')),
              if (_canEdit && !offline) const PopupMenuItem(value: 'delete',
                  child: Text('Delete', style: TextStyle(color: AppColors.negative))),
            ],
          ),
          onTap: _canEdit && !offline ? () => _openEdit(tax) : null,
        );
      },
    );
  }

  // ── Form Panel ────────────────────────────────────────────────────────────────

  Widget _formTitleBlock(bool isEdit) => Text(
      isEdit ? 'Edit Tax' : 'New Tax',
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
          color: AppColors.textPrimary));

  Widget _formCloseButton() => IconButton(
      icon: const Icon(Icons.close, size: 18), onPressed: _closePanel);

  Widget _formActionButtons(bool isEdit, bool offline) =>
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (isEdit ? _canEdit : _canAdd)
          FilledButton(
            onPressed: (_saving || offline) ? null : _saveTax,
            child: _saving
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Text(isEdit ? 'Update Tax' : 'Save Tax'),
          ),
      ]);

  Widget _formPanel() {
    final isEdit = _panelMode == 'edit';
    final offline = ref.watch(sessionProvider)?.offlineMode ?? false;
    final mobile = Responsive.isMobile(context);
    final isCompact = ref.watch(isCompactDensityProvider);
    final fieldStyle = SakalFieldCard.valueTextStyle(isCompact);
    InputDecoration bare({String? hint}) => hint == null
        ? SakalFieldCard.bareDecoration
        : SakalFieldCard.bareDecoration.copyWith(
            hintText: hint,
            hintStyle: const TextStyle(fontSize: 12, color: AppColors.textDisabled, fontWeight: FontWeight.normal),
          );
    return Column(children: [
      Container(
        color: AppColors.surface,
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
        child: mobile
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: _formTitleBlock(isEdit)),
                  _formCloseButton(),
                ]),
                const SizedBox(height: 10),
                _formActionButtons(isEdit, offline),
              ])
            : Row(children: [
                Expanded(child: _formTitleBlock(isEdit)),
                _formActionButtons(isEdit, offline),
                const SizedBox(width: 8),
                _formCloseButton(),
              ]),
      ),
      const Divider(height: 1, color: AppColors.border),
      Expanded(
        child: SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Form(
        key: _formKey,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Code + Name
          SakalFieldRow(isMobile: mobile, spans: const [4, 8], children: [
            isEdit
                ? SakalFieldCard.readOnly(label: 'Tax Code', value: _codeCtrl.text)
                : SakalFieldCard(
                    label: 'Tax Code',
                    required: true,
                    editable: true,
                    child: TextFormField(
                      controller: _codeCtrl,
                      textCapitalization: TextCapitalization.characters,
                      style: fieldStyle,
                      decoration: bare(),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                  ),
            SakalFieldCard(
              label: 'Tax Name',
              required: true,
              editable: true,
              child: TextFormField(
                controller: _nameCtrl,
                style: fieldStyle,
                decoration: bare(),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
            ),
          ]),
          const SizedBox(height: 14),

          // Tax Type
          SakalFieldCard(
            label: 'Tax Type',
            required: true,
            editable: true,
            child: DropdownButtonFormField<String>(
              initialValue: _taxTypes.isEmpty ? null : _selTypeCode,
              isExpanded: true, isDense: true, itemHeight: null,
              style: fieldStyle,
              decoration: bare(),
              items: _taxTypes.map((t) => DropdownMenuItem(
                value: t.taxTypeCode,
                child: Text(t.typeName, overflow: TextOverflow.ellipsis),
              )).toList(),
              validator: (v) => (v == null || v.isEmpty) ? 'Required — run SQL migration 025 in Supabase first' : null,
              onChanged: (v) => setState(() {
                _selTypeCode  = v!;
                // Auto-clear reverse charge if not a withholding type
                if (_taxTypes.firstWhere((t) => t.taxTypeCode == v, orElse: () =>
                      const TaxTypeModel(id:'',taxTypeCode:'',typeName:'',isWithholding:false,sortOrder:0,isActive:true))
                    .isWithholding == false) {
                  _formReverse = false;
                }
              }),
            ),
          ),
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

          // Calculation Type
          Text('Calculation Type', style: TextStyle(color: Colors.grey.shade700, fontSize: 12)),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'PERCENTAGE',   label: Text('Percentage')),
              ButtonSegment(value: 'FIXED_AMOUNT', label: Text('Fixed')),
              ButtonSegment(value: 'COMPOUND',     label: Text('Compound')),
            ],
            selected: {_selCalcType},
            onSelectionChanged: (s) => setState(() => _selCalcType = s.first),
          ),
          if (_selCalcType == 'COMPOUND') ...[
            const SizedBox(height: 12),
            _compoundSourcesSection(),
          ],
          const SizedBox(height: 14),

          // Switches
          Row(children: [
            Expanded(child: SwitchListTile.adaptive(
              dense: true,
              title: const Text('Price Inclusive', style: TextStyle(fontSize: 13)),
              subtitle: const Text('Tax included in listed price', style: TextStyle(fontSize: 11)),
              value: _formInclusive,
              onChanged: (v) => setState(() => _formInclusive = v),
            )),
            if (_taxTypes.firstWhere(
                (t) => t.taxTypeCode == _selTypeCode,
                orElse: () => const TaxTypeModel(id:'',taxTypeCode:'',typeName:'',isWithholding:false,sortOrder:0,isActive:true))
                .isWithholding)
              Expanded(child: SwitchListTile.adaptive(
                dense: true,
                title: const Text('Reverse Charge', style: TextStyle(fontSize: 13)),
                subtitle: const Text('Liability shifts to buyer', style: TextStyle(fontSize: 11)),
                value: _formReverse,
                onChanged: (v) => setState(() => _formReverse = v),
              )),
          ]),
          const SizedBox(height: 14),

          // GL Accounts
          _sectionLabel('GL Accounts (optional — wire up after COA is configured)'),
          const SizedBox(height: 8),
          if (_accounts.isNotEmpty) ...[
            SakalFieldCard(
              label: 'Output Account (Sales — Cr)',
              editable: true,
              child: _accountPicker(selectedId: _outAccountId,
                  onSelected: (id) => setState(() => _outAccountId = id)),
            ),
            const SizedBox(height: 10),
            SakalFieldCard(
              label: 'Input Account (Purchase — Dr, recoverable)',
              editable: true,
              child: _accountPicker(selectedId: _inAccountId,
                  onSelected: (id) => setState(() => _inAccountId = id)),
            ),
            const SizedBox(height: 10),
            SakalFieldCard(
              label: 'Expense Account (Non-recoverable / WHT absorbed — Dr)',
              editable: true,
              child: _accountPicker(selectedId: _expAccountId,
                  onSelected: (id) => setState(() => _expAccountId = id)),
            ),
            const SizedBox(height: 14),
          ] else
            Text('No posting accounts available. Set up Chart of Accounts first.',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),

          // Sort Order + Active
          SakalFieldRow(isMobile: mobile, spans: const [4, 8], children: [
            SakalFieldCard(
              label: 'Sort Order',
              editable: true,
              numeric: true,
              child: TextFormField(
                controller: _sortCtrl,
                textAlign: TextAlign.right,
                keyboardType: TextInputType.number,
                style: fieldStyle,
                decoration: bare(),
              ),
            ),
            SwitchListTile.adaptive(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Active', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
              value: _formActive,
              activeThumbColor: AppColors.positive,
              onChanged: (v) => setState(() => _formActive = v),
            ),
          ]),

          // Inline Rates (only in edit mode)
          if (isEdit && _editing?.id != null) ...[
            const SizedBox(height: 28),
            _ratesSection(),
          ],
        ]),
      ),
        ),
      ),
    ]);
  }

  Widget _compoundSourcesSection() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _sectionLabel('Compound Sources (tax is a % of these taxes combined)'),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 6,
        children: _taxes
            .where((t) => t.id != _editing?.id && t.calculationType != 'COMPOUND')
            .map((t) {
          final selected = _compoundSourceIds.contains(t.id);
          return FilterChip(
            label: Text(t.taxCode, style: const TextStyle(fontSize: 12)),
            selected: selected,
            onSelected: (_) => setState(() {
              if (selected) {
                _compoundSourceIds.remove(t.id);
              } else if (t.id != null) {
                _compoundSourceIds.add(t.id!);
              }
            }),
          );
        }).toList(),
      ),
    ],
  );

  // ── Rates Section ────────────────────────────────────────────────────────────

  Widget _ratesSection() {
    final rates = _ratesFor(_editing!.id!);
    final offline = ref.watch(sessionProvider)?.offlineMode ?? false;
    return ExpansionTile(
      initiallyExpanded: true,
      title: const Text('Tax Rates', style: TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text('${rates.length} rate(s) configured'),
      trailing: (_canEdit && !offline)
          ? TextButton.icon(
              onPressed: _openAddRate,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add Rate'),
            ) : const Icon(Icons.expand_more),
      children: [
        if (rates.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('No rates. Add at least one STANDARD rate.'),
          ),
        ...rates.map((r) => _rateRow(r)),
        if (_showRateForm) _rateFormRow(),
      ],
    );
  }

  Widget _rateRow(TaxRateModel r) {
    final offline = ref.watch(sessionProvider)?.offlineMode ?? false;
    final from  = r.effectiveFrom.toIso8601String().substring(0, 10);
    final to    = r.effectiveTo?.toIso8601String().substring(0, 10) ?? '—';
    final badge = r.isCurrent ? 'Current' : (r.effectiveTo != null ? 'Expired' : 'Future');
    final badgeColor = badge == 'Current' ? AppColors.positive
        : badge == 'Expired' ? Colors.grey : Colors.orange;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Card(
        child: ListTile(
          dense: true,
          leading: Chip(
            label: Text(r.rateLabel, style: const TextStyle(fontSize: 10)),
            padding: EdgeInsets.zero,
            backgroundColor: AppColors.primary.withValues(alpha: 0.12),
          ),
          title: Text('${r.rate.toStringAsFixed(4)}%  ($from → $to)',
              style: const TextStyle(fontSize: 12)),
          subtitle: r.isActive ? null : const Text('Inactive', style: TextStyle(fontSize: 10)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Chip(label: Text(badge, style: const TextStyle(fontSize: 10, color: Colors.white)),
                backgroundColor: badgeColor, padding: EdgeInsets.zero),
            if (_canEdit && !offline) ...[
              const SizedBox(width: 4),
              IconButton(icon: const Icon(Icons.edit, size: 16), onPressed: () => _openEditRate(r)),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _rateFormRow() {
    final offline = ref.watch(sessionProvider)?.offlineMode ?? false;
    return Padding(
    padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
    child: Card(
      color: AppColors.primary.withValues(alpha: 0.04),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_editingRate == null ? 'Add Rate' : 'Edit Rate',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 10),
          Row(children: [
            // Rate Label
            SizedBox(width: 130,
              child: DropdownButtonFormField<String>(
                initialValue: _rateLabel,
                isDense: true,
                decoration: const InputDecoration(labelText: 'Label', isDense: true),
                items: ['STANDARD','REDUCED','ZERO','EXEMPT','SPECIAL']
                    .map((l) => DropdownMenuItem(value: l, child: Text(l, style: const TextStyle(fontSize: 12))))
                    .toList(),
                onChanged: (v) => setState(() => _rateLabel = v!),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(width: 90,
              child: TextFormField(
                controller: _rateCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Rate %', isDense: true),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(width: 120,
              child: TextFormField(
                controller: _rateFromCtrl,
                decoration: const InputDecoration(labelText: 'Effective From', isDense: true,
                    hintText: 'YYYY-MM-DD'),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(width: 120,
              child: TextFormField(
                controller: _rateToCtrl,
                decoration: const InputDecoration(labelText: 'Effective To', isDense: true,
                    hintText: 'YYYY-MM-DD'),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            Switch(
              value: _rateActive,
              onChanged: (v) => setState(() => _rateActive = v),
              thumbColor: WidgetStateProperty.resolveWith((s) =>
                  s.contains(WidgetState.selected) ? Colors.white : Colors.grey.shade400),
              trackColor: WidgetStateProperty.resolveWith((s) =>
                  s.contains(WidgetState.selected) ? AppColors.primary : AppColors.surfaceVariant),
              trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
            ),
            const SizedBox(width: 4),
            const Text('Active', style: TextStyle(fontSize: 12)),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            FilledButton(
              onPressed: (_saving || offline) ? null : _saveRate,
              style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary, minimumSize: const Size(80, 36)),
              child: _saving ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Save Rate'),
            ),
            const SizedBox(width: 8),
            TextButton(onPressed: () => setState(() { _showRateForm = false; _editingRate = null; }),
                child: const Text('Cancel')),
          ]),
        ]),
      ),
    ),
  );
  }

  Widget _sectionLabel(String label) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade600,
        fontWeight: FontWeight.w600)),
  );
}
