import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';

/// Shared Sales+Purchase charge type master (freight, loading, handling…).
/// See backend/migrations/031_purchase_orders.sql — rim_additional_charges.
class AdditionalChargesScreen extends ConsumerStatefulWidget {
  const AdditionalChargesScreen({super.key});

  @override
  ConsumerState<AdditionalChargesScreen> createState() => _AdditionalChargesScreenState();
}

class _AdditionalChargesScreenState extends ConsumerState<AdditionalChargesScreen>
    with ScreenPermissionMixin<AdditionalChargesScreen> {
  @override String get screenName => '/master/additional-charges';

  List<Map<String, dynamic>> _rows  = [];
  List<Map<String, dynamic>> _taxes = [];
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
        DioClient.instance.get('/rim_additional_charges', queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false',
          'select':     '*,tax:rim_taxes!tax_id(tax_code,tax_name),'
              'account:rim_accounts!default_gl_account_id(account_code,account_name)',
          'order':      'sort_order.asc,charge_code.asc',
        }),
        DioClient.instance.get('/rim_taxes', queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false',
          'is_active':  'eq.true',
          'select':     'id,tax_code,tax_name',
          'order':      'tax_code.asc',
        }),
      ]);
      if (mounted) {
        setState(() {
          _rows    = List<Map<String, dynamic>>.from(results[0].data as List);
          _taxes   = List<Map<String, dynamic>>.from(results[1].data as List);
          _loading = false;
        });
      }
    } on DioException {
      if (mounted) setState(() { _loading = false; _error = 'Could not load additional charges.'; });
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppColors.negative));
  }

  Future<void> _save(Map<String, dynamic> payload, {required Map<String, dynamic>? existing}) async {
    final session = ref.read(sessionProvider)!;
    final now     = DateTime.now().toUtc().toIso8601String();
    final id      = payload['id'] as String;
    try {
      if (existing != null) {
        await DioClient.instance.patch(
          '/rim_additional_charges',
          queryParameters: {'id': 'eq.$id'},
          data: {...payload, 'updated_at': now, 'updated_by': session.userId}
            ..remove('id')..remove('client_id')..remove('company_id'),
          options: Options(headers: {'Prefer': 'return=minimal'}),
        );
      } else {
        await DioClient.instance.post(
          '/rim_additional_charges',
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
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      _load();
    } on DioException catch (e) {
      _showError(e.response?.data?['message'] as String? ?? 'Save failed. Please try again.');
    } catch (e) {
      _showError('Unexpected error: $e');
    }
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    try {
      await DioClient.instance.patch(
        '/rim_additional_charges',
        queryParameters: {'id': 'eq.${row['id']}'},
        data: {'is_deleted': true, 'updated_at': DateTime.now().toUtc().toIso8601String()},
        options: Options(headers: {'Prefer': 'return=minimal'}),
      );
      _load();
    } on DioException {
      _showError('Could not delete charge type.');
    }
  }

  Future<void> _confirmDelete(Map<String, dynamic> row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Charge Type?'),
        content: Text('Remove "${row['charge_name']}"?'),
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
      builder: (_) => _ChargeDialog(
        existing: existing,
        taxes: _taxes,
        onSave: (payload) => _save(payload, existing: existing),
      ),
    );
  }

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
              Row(children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Additional Charges',
                          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                      SizedBox(height: 4),
                      Text('Shared charge types for Sales and Purchase — freight, loading, handling, insurance…',
                          style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                    ],
                  ),
                ),
                if (canAdd && !offline)
                  ElevatedButton.icon(
                    onPressed: () => _openDialog(),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add Charge'),
                  ),
              ]),
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
                  child: Row(children: [
                    const Icon(Icons.error_outline, color: AppColors.negative, size: 18),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_error!, style: const TextStyle(fontSize: 13, color: AppColors.negative))),
                    TextButton(onPressed: _load, child: const Text('Retry')),
                  ]),
                ),
                const SizedBox(height: 20),
              ],

              Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: _loading
                    ? const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
                    : _rows.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(40),
                            child: Center(
                              child: Column(children: [
                                Icon(Icons.receipt_long_outlined, size: 40, color: AppColors.textSecondary),
                                SizedBox(height: 12),
                                Text('No charge types yet.', style: TextStyle(color: AppColors.textSecondary)),
                                Text('Click "Add Charge" to create one.',
                                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                              ]),
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

  Widget _buildTableHeader() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: const BoxDecoration(
      color: AppColors.surfaceVariant,
      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
    ),
    child: const Row(children: [
      SizedBox(width: 90,  child: _HCol('Code')),
      SizedBox(width: 170, child: _HCol('Name')),
      SizedBox(width: 100, child: _HCol('Applies To')),
      SizedBox(width: 100, child: _HCol('Nature')),
      SizedBox(width: 130, child: _HCol('Default')),
      SizedBox(width: 110, child: _HCol('Tax')),
      SizedBox(width: 80,  child: _HCol('Active')),
      SizedBox(width: 90,  child: _HCol('Actions')),
    ]),
  );

  Widget _buildRow(Map<String, dynamic> row, bool isEven) {
    final active  = row['is_active'] as bool? ?? true;
    final tax     = row['tax'] as Map<String, dynamic>?;
    final isPct   = row['amount_or_percent'] == 'PERCENT';
    final defVal  = isPct ? row['default_percent'] : row['default_amount'];
    final defText = defVal != null
        ? (isPct ? '${(defVal as num).toStringAsFixed(2)}%' : (defVal as num).toStringAsFixed(2))
        : '—';
    final offline = ref.watch(sessionProvider)?.offlineMode ?? false;
    return Container(
      color: isEven ? Colors.transparent : AppColors.surfaceVariant.withValues(alpha: 0.35),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(width: 90, child: Text(row['charge_code'] ?? '',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary))),
          SizedBox(width: 170, child: Text(row['charge_name'] ?? '',
              style: const TextStyle(fontSize: 13, color: AppColors.textPrimary))),
          SizedBox(width: 100, child: Text(row['applicable_on'] ?? '',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))),
          SizedBox(width: 100, child: Text(row['nature'] == 'DEDUCT' ? 'Deduct' : 'Add',
              style: TextStyle(fontSize: 12,
                  color: row['nature'] == 'DEDUCT' ? AppColors.negative : AppColors.positive))),
          SizedBox(width: 130, child: Text(defText, style: const TextStyle(fontSize: 12))),
          SizedBox(width: 110, child: Text(
              (row['is_taxable'] as bool? ?? false) ? (tax?['tax_code'] as String? ?? '—') : 'Non-taxable',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))),
          SizedBox(
            width: 80,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: (active ? AppColors.positive : AppColors.textDisabled).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(active ? 'Active' : 'Inactive',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                      color: active ? AppColors.positive : AppColors.textSecondary)),
            ),
          ),
          SizedBox(
            width: 90,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
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
            ]),
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
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textSecondary, letterSpacing: 0.3));
}

// ── Add / Edit Dialog ───────────────────────────────────────────────────────

class _ChargeDialog extends ConsumerStatefulWidget {
  final Map<String, dynamic>? existing;
  final List<Map<String, dynamic>> taxes;
  final void Function(Map<String, dynamic> payload) onSave;
  const _ChargeDialog({this.existing, required this.taxes, required this.onSave});

  @override
  ConsumerState<_ChargeDialog> createState() => _ChargeDialogState();
}

class _ChargeDialogState extends ConsumerState<_ChargeDialog> {
  final _formKey  = GlobalKey<FormState>();
  final _codeCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _sortCtrl = TextEditingController(text: '0');
  final _valueCtrl = TextEditingController();

  String  _applicableOn = 'BOTH';
  String  _nature       = 'ADD';
  String  _amountOrPercent = 'AMOUNT';
  bool    _isTaxable = false;
  String? _taxId;
  String? _glAccountId;
  bool    _isActive = true;
  bool    _saving   = false;

  bool get _isEdit => widget.existing != null;

  static Widget _req(String text) => RichText(
    text: TextSpan(
      text: text,
      style: const TextStyle(color: AppColors.textSecondary, fontSize: 14, fontWeight: FontWeight.w400),
      children: const [TextSpan(text: ' *', style: TextStyle(color: AppColors.negative, fontWeight: FontWeight.w600))],
    ),
  );

  @override
  void initState() {
    super.initState();
    final d = widget.existing;
    if (d != null) {
      _codeCtrl.text   = d['charge_code'] ?? '';
      _nameCtrl.text   = d['charge_name'] ?? '';
      _sortCtrl.text   = (d['sort_order'] ?? 0).toString();
      _applicableOn    = d['applicable_on'] as String? ?? 'BOTH';
      _nature          = d['nature'] as String? ?? 'ADD';
      _amountOrPercent = d['amount_or_percent'] as String? ?? 'AMOUNT';
      _isTaxable       = d['is_taxable'] as bool? ?? false;
      _taxId           = d['tax_id'] as String?;
      _glAccountId     = d['default_gl_account_id'] as String?;
      _isActive        = d['is_active'] as bool? ?? true;
      final v = _amountOrPercent == 'PERCENT' ? d['default_percent'] : d['default_amount'];
      _valueCtrl.text  = v != null ? (v as num).toString() : '';
    }
  }

  @override
  void dispose() {
    _codeCtrl.dispose(); _nameCtrl.dispose(); _sortCtrl.dispose(); _valueCtrl.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all required fields.'), backgroundColor: Colors.orange));
      return;
    }
    setState(() => _saving = true);
    final value = double.tryParse(_valueCtrl.text.trim());
    widget.onSave({
      'id':                    widget.existing?['id'] as String? ?? const Uuid().v4(),
      'charge_code':           _codeCtrl.text.trim().toUpperCase(),
      'charge_name':           _nameCtrl.text.trim(),
      'applicable_on':         _applicableOn,
      'is_taxable':            _isTaxable,
      'tax_id':                _isTaxable ? _taxId : null,
      'nature':                _nature,
      'amount_or_percent':     _amountOrPercent,
      'default_percent':       _amountOrPercent == 'PERCENT' ? value : null,
      'default_amount':        _amountOrPercent == 'AMOUNT'  ? value : null,
      'default_gl_account_id': _glAccountId,
      'sort_order':            int.tryParse(_sortCtrl.text) ?? 0,
      'is_active':             _isActive,
    });
  }

  String _displayAccount(Map<String, dynamic> a) => '[${a['account_code']}] ${a['account_name']}';

  Widget _accountPicker(List<Map<String, dynamic>> accounts) {
    final matches  = accounts.where((a) => a['id'] == _glAccountId).toList();
    final selected = matches.isNotEmpty ? matches.first : null;
    return SizedBox(
      height: 56,
      child: Autocomplete<Map<String, dynamic>>(
        key: ValueKey(_glAccountId ?? 'none'),
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
          onChanged: (v) { if (v.isEmpty) setState(() => _glAccountId = null); },
          decoration: const InputDecoration(labelText: 'Default GL Account', prefixIcon: Icon(Icons.account_balance_outlined)),
          style: const TextStyle(fontSize: 13),
        ),
        onSelected: (a) => setState(() => _glAccountId = a['id'] as String?),
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
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Form(
            key: _formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(_isEdit ? Icons.edit_outlined : Icons.add_box_outlined, color: AppColors.primary, size: 22),
                    const SizedBox(width: 10),
                    Text(_isEdit ? 'Edit Charge Type' : 'Add Charge Type',
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                    const Spacer(),
                    IconButton(icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(context, rootNavigator: true).pop()),
                  ]),
                  const SizedBox(height: 20),

                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(flex: 2, child: TextFormField(
                      controller: _codeCtrl,
                      textCapitalization: TextCapitalization.characters,
                      enabled: !_isEdit,
                      decoration: InputDecoration(label: _req('Code'), prefixIcon: const Icon(Icons.tag_outlined)),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                    )),
                    const SizedBox(width: 12),
                    Expanded(flex: 3, child: TextFormField(
                      controller: _nameCtrl,
                      decoration: InputDecoration(label: _req('Name'), prefixIcon: const Icon(Icons.label_outline)),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                    )),
                  ]),
                  const SizedBox(height: 14),

                  Text('Applies To', style: TextStyle(color: Colors.grey.shade700, fontSize: 12)),
                  const SizedBox(height: 6),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'SALES',    label: Text('Sales')),
                      ButtonSegment(value: 'PURCHASE', label: Text('Purchase')),
                      ButtonSegment(value: 'BOTH',     label: Text('Both')),
                    ],
                    selected: {_applicableOn},
                    onSelectionChanged: (s) => setState(() => _applicableOn = s.first),
                  ),
                  const SizedBox(height: 14),

                  Text('Nature', style: TextStyle(color: Colors.grey.shade700, fontSize: 12)),
                  const SizedBox(height: 6),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'ADD',    label: Text('Add to cost')),
                      ButtonSegment(value: 'DEDUCT', label: Text('Deduct (rebate)')),
                    ],
                    selected: {_nature},
                    onSelectionChanged: (s) => setState(() => _nature = s.first),
                  ),
                  const SizedBox(height: 14),

                  Row(children: [
                    SizedBox(
                      width: 150,
                      child: DropdownButtonFormField<String>(
                        initialValue: _amountOrPercent,
                        decoration: const InputDecoration(labelText: 'Default Type'),
                        items: const [
                          DropdownMenuItem(value: 'AMOUNT',  child: Text('Amount')),
                          DropdownMenuItem(value: 'PERCENT', child: Text('Percent')),
                        ],
                        onChanged: (v) => setState(() => _amountOrPercent = v!),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: TextFormField(
                      controller: _valueCtrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                          labelText: _amountOrPercent == 'PERCENT' ? 'Default %' : 'Default Amount'),
                    )),
                  ]),
                  const SizedBox(height: 6),
                  Text('Editable per transaction — only the type (Amount/Percent) is locked.',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                  const SizedBox(height: 14),

                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Taxable', style: TextStyle(fontSize: 14)),
                    subtitle: const Text('This charge itself attracts tax', style: TextStyle(fontSize: 11)),
                    value: _isTaxable,
                    onChanged: (v) => setState(() { _isTaxable = v; if (!v) _taxId = null; }),
                    activeThumbColor: AppColors.positive,
                  ),
                  if (_isTaxable) ...[
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      initialValue: _taxId,
                      decoration: const InputDecoration(labelText: 'Tax'),
                      items: widget.taxes.map((t) => DropdownMenuItem(
                        value: t['id'] as String,
                        child: Text('${t['tax_code']} — ${t['tax_name']}', style: const TextStyle(fontSize: 13)),
                      )).toList(),
                      onChanged: (v) => setState(() => _taxId = v),
                      validator: (v) => (_isTaxable && (v == null || v.isEmpty)) ? 'Select a tax' : null,
                    ),
                  ],
                  const SizedBox(height: 14),

                  accountsAsync.when(
                    data: (accounts) => _accountPicker(
                        accounts.where((a) => a['posting_allowed'] == true).toList()),
                    loading: () => const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                    error: (e, _) => Text('Could not load accounts: $e',
                        style: const TextStyle(fontSize: 12, color: AppColors.negative)),
                  ),
                  const SizedBox(height: 14),

                  Row(children: [
                    SizedBox(width: 100, child: TextFormField(
                      controller: _sortCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Sort Order'),
                    )),
                    const Spacer(),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Active', style: TextStyle(fontSize: 14)),
                      value: _isActive,
                      onChanged: (v) => setState(() => _isActive = v),
                      activeThumbColor: AppColors.positive,
                    ),
                  ]),
                  const SizedBox(height: 20),

                  Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    TextButton(
                        onPressed: _saving ? null : () => Navigator.of(context, rootNavigator: true).pop(),
                        child: const Text('Cancel')),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 140,
                      child: ElevatedButton(
                        onPressed: _saving ? null : _save,
                        child: _saving
                            ? const SizedBox(height: 18, width: 18,
                                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                            : Text(_isEdit ? 'Save Changes' : 'Add Charge'),
                      ),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
