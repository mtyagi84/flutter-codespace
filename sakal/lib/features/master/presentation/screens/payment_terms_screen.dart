import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_presets.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../../../core/widgets/sakal_field_card.dart';
import '../../../../core/widgets/sakal_field_row.dart';

/// Payment Terms master — Odoo-shaped (account.payment.term /
/// account.payment.term.line): a header + installment lines, referenced
/// by id from Sales Order (and future Sales Quotation/Purchase Order
/// screens) rather than the old free-text payment_terms columns.
/// See backend/migrations/086_payment_terms_and_currency_aware_pricing.sql.
class PaymentTermsScreen extends ConsumerStatefulWidget {
  const PaymentTermsScreen({super.key});

  @override
  ConsumerState<PaymentTermsScreen> createState() => _PaymentTermsScreenState();
}

class _PaymentTermsScreenState extends ConsumerState<PaymentTermsScreen>
    with ScreenPermissionMixin<PaymentTermsScreen> {
  @override String get screenName => '/master/payment-terms';

  List<Map<String, dynamic>> _rows = [];
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
      final res = await DioClient.instance.get('/rim_payment_terms', queryParameters: {
        'client_id':  'eq.${session.clientId}',
        'company_id': 'eq.${session.companyId}',
        'is_deleted': 'eq.false',
        'select':     '*',
        'order':      'term_name.asc',
      });
      if (mounted) {
        setState(() { _rows = List<Map<String, dynamic>>.from(res.data as List); _loading = false; });
      }
    } on DioException {
      if (mounted) setState(() { _loading = false; _error = 'Could not load payment terms.'; });
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppColors.negative));
  }

  Future<List<Map<String, dynamic>>> _loadLines(String termId) async {
    final session = ref.read(sessionProvider)!;
    final res = await DioClient.instance.get('/rim_payment_term_lines', queryParameters: {
      'client_id':  'eq.${session.clientId}',
      'company_id': 'eq.${session.companyId}',
      'term_id':    'eq.$termId',
      'is_deleted': 'eq.false',
      'select':     'sequence,value_type,value_amount,due_days,is_end_of_month',
      'order':      'sequence.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<void> _save(Map<String, dynamic> header, List<Map<String, dynamic>> lines) async {
    final session = ref.read(sessionProvider)!;
    try {
      await DioClient.instance.post('/rpc/fn_save_payment_term', data: {
        'p_header': {
          ...header,
          'client_id':  session.clientId,
          'company_id': session.companyId,
        },
        'p_lines':   lines,
        'p_user_id': session.userId,
      });
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
        '/rim_payment_terms',
        queryParameters: {'id': 'eq.${row['id']}'},
        data: {'is_deleted': true, 'updated_at': DateTime.now().toUtc().toIso8601String()},
        options: Options(headers: {'Prefer': 'return=minimal'}),
      );
      _load();
    } on DioException {
      _showError('Could not delete payment term.');
    }
  }

  Future<void> _confirmDelete(Map<String, dynamic> row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Payment Term?'),
        content: Text('Remove "${row['term_name']}"?'),
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

  Future<void> _openDialog([Map<String, dynamic>? existing]) async {
    List<Map<String, dynamic>> existingLines = const [];
    if (existing != null) {
      existingLines = await _loadLines(existing['id'] as String);
    }
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PaymentTermDialog(
        existing: existing,
        existingLines: existingLines,
        onSave: _save,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final offline  = ref.watch(sessionProvider)?.offlineMode ?? false;
    final isMobile = Responsive.isMobile(context);
    final addButton = (canAdd && !offline)
        ? ElevatedButton.icon(
            onPressed: () => _openDialog(),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add Payment Term'),
          )
        : null;
    return SingleChildScrollView(
      padding: EdgeInsets.all(isMobile ? 16 : 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isMobile) ...[
                const Text('Payment Terms',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                const SizedBox(height: 4),
                const Text('Installment schedules referenced by Sales Order and future documents.',
                    style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                if (addButton != null) ...[
                  const SizedBox(height: 12),
                  SizedBox(width: double.infinity, child: addButton),
                ],
              ] else
                Row(children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Payment Terms',
                            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                        SizedBox(height: 4),
                        Text('Installment schedules referenced by Sales Order and future documents.',
                            style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                  if (addButton != null) addButton,
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
                                Icon(Icons.schedule_outlined, size: 40, color: AppColors.textSecondary),
                                SizedBox(height: 12),
                                Text('No payment terms yet.', style: TextStyle(color: AppColors.textSecondary)),
                                Text('Click "Add Payment Term" to create one.',
                                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                              ]),
                            ),
                          )
                        : isMobile
                            ? Column(children: _rows.map((r) => _buildMobileCard(r, offline)).toList())
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _buildTableHeader(),
                                  const Divider(height: 1),
                                  ..._rows.asMap().entries.map((e) => _buildRow(e.value, e.key.isEven, offline)),
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
      Expanded(flex: 2, child: _HCol('Code')),
      Expanded(flex: 3, child: _HCol('Name')),
      Expanded(flex: 4, child: _HCol('Description')),
      Expanded(flex: 2, child: _HCol('Active')),
      SizedBox(width: 90, child: _HCol('Actions')),
    ]),
  );

  Widget _buildRow(Map<String, dynamic> row, bool isEven, bool offline) {
    final active = row['is_active'] as bool? ?? true;
    final tint = ThemePresetConfig.all[ref.watch(themePresetProvider)]!.primary;
    return Container(
      color: isEven ? Colors.transparent : AppColors.surfaceVariant.withValues(alpha: 0.35),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(flex: 2, child: Text(row['term_code'] ?? '',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
              overflow: TextOverflow.ellipsis)),
          Expanded(flex: 3, child: Text(row['term_name'] ?? '',
              style: const TextStyle(fontSize: 13, color: AppColors.textPrimary),
              overflow: TextOverflow.ellipsis)),
          Expanded(flex: 4, child: Text(row['description'] as String? ?? '—',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
              overflow: TextOverflow.ellipsis)),
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.centerLeft,
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
          ),
          SizedBox(
            width: 90,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                tooltip: 'Edit',
                icon: Icon(Icons.edit_outlined, size: 18, color: tint),
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

  Widget _buildMobileCard(Map<String, dynamic> row, bool offline) {
    final active = row['is_active'] as bool? ?? true;
    final tint = ThemePresetConfig.all[ref.watch(themePresetProvider)]!.primary;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('${row['term_code']}  ${row['term_name']}',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: (active ? AppColors.positive : AppColors.textDisabled).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(active ? 'Active' : 'Inactive',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                    color: active ? AppColors.positive : AppColors.textSecondary)),
          ),
        ]),
        if ((row['description'] as String?)?.isNotEmpty ?? false) ...[
          const SizedBox(height: 6),
          Text(row['description'] as String, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        ],
        const SizedBox(height: 4),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          IconButton(
            tooltip: 'Edit',
            icon: Icon(Icons.edit_outlined, size: 20, color: tint),
            onPressed: (canEdit && !offline) ? () => _openDialog(row) : null,
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline, size: 20, color: AppColors.negative),
            onPressed: (canEdit && !offline) ? () => _confirmDelete(row) : null,
          ),
        ]),
      ]),
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

class _TermLineRow {
  String valueType = 'PERCENT';
  final TextEditingController valueCtrl = TextEditingController(text: '0');
  final TextEditingController dueDaysCtrl = TextEditingController(text: '0');
  bool isEndOfMonth = false;

  void dispose() { valueCtrl.dispose(); dueDaysCtrl.dispose(); }
}

class _PaymentTermDialog extends ConsumerStatefulWidget {
  final Map<String, dynamic>? existing;
  final List<Map<String, dynamic>> existingLines;
  final void Function(Map<String, dynamic> header, List<Map<String, dynamic>> lines) onSave;
  const _PaymentTermDialog({this.existing, required this.existingLines, required this.onSave});

  @override
  ConsumerState<_PaymentTermDialog> createState() => _PaymentTermDialogState();
}

class _PaymentTermDialogState extends ConsumerState<_PaymentTermDialog> {
  final _formKey  = GlobalKey<FormState>();
  final _codeCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  bool  _isActive = true;
  bool  _saving   = false;

  final List<_TermLineRow> _lines = [];

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
      _codeCtrl.text = d['term_code'] as String? ?? '';
      _nameCtrl.text = d['term_name'] as String? ?? '';
      _descCtrl.text = d['description'] as String? ?? '';
      _isActive      = d['is_active'] as bool? ?? true;
    }
    if (widget.existingLines.isNotEmpty) {
      for (final l in widget.existingLines) {
        final row = _TermLineRow()
          ..valueType = l['value_type'] as String? ?? 'PERCENT'
          ..isEndOfMonth = l['is_end_of_month'] as bool? ?? false;
        row.valueCtrl.text = (l['value_amount'] as num? ?? 0).toString();
        row.dueDaysCtrl.text = (l['due_days'] as num? ?? 0).toString();
        _lines.add(row);
      }
    } else {
      _lines.add(_TermLineRow());
    }
  }

  @override
  void dispose() {
    _codeCtrl.dispose(); _nameCtrl.dispose(); _descCtrl.dispose();
    for (final l in _lines) { l.dispose(); }
    super.dispose();
  }

  void _addLine() => setState(() => _lines.add(_TermLineRow()));
  void _removeLine(_TermLineRow row) => setState(() { if (_lines.length > 1) { _lines.remove(row); row.dispose(); } });

  void _save() {
    if (!_formKey.currentState!.validate()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all required fields.'), backgroundColor: Colors.orange));
      return;
    }
    setState(() => _saving = true);
    final header = {
      'term_id':     widget.existing?['id'] as String?,
      'term_code':   _codeCtrl.text.trim().toUpperCase(),
      'term_name':   _nameCtrl.text.trim(),
      'description': _descCtrl.text.trim(),
      'is_active':   _isActive,
    };
    final lines = _lines.asMap().entries.map((e) => {
      'sequence':        e.key + 1,
      'value_type':      e.value.valueType,
      'value_amount':    double.tryParse(e.value.valueCtrl.text) ?? 0,
      'due_days':        int.tryParse(e.value.dueDaysCtrl.text) ?? 0,
      'is_end_of_month': e.value.isEndOfMonth,
    }).toList();
    widget.onSave(header, lines);
  }

  @override
  Widget build(BuildContext context) {
    final tint = ThemePresetConfig.all[ref.watch(themePresetProvider)]!.primary;
    final isCompact = ref.watch(isCompactDensityProvider);
    final fieldStyle = SakalFieldCard.valueTextStyle(isCompact);
    final mobile = Responsive.isMobile(context);
    InputDecoration bare({String? hint}) => hint == null
        ? SakalFieldCard.bareDecoration
        : SakalFieldCard.bareDecoration.copyWith(
            hintText: hint,
            hintStyle: const TextStyle(fontSize: 12, color: AppColors.textDisabled, fontWeight: FontWeight.normal),
          );
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
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
                    Icon(_isEdit ? Icons.edit_outlined : Icons.add_box_outlined, color: tint, size: 22),
                    const SizedBox(width: 10),
                    Text(_isEdit ? 'Edit Payment Term' : 'Add Payment Term',
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                    const Spacer(),
                    IconButton(icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(context, rootNavigator: true).pop()),
                  ]),
                  const SizedBox(height: 20),

                  SakalFieldRow(isMobile: mobile, spans: const [4, 8], children: [
                    _isEdit
                        ? SakalFieldCard.readOnly(label: 'Code', value: _codeCtrl.text)
                        : SakalFieldCard(
                            label: 'Code',
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
                      label: 'Name',
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

                  SakalFieldCard(
                    label: 'Description (printable summary)',
                    editable: true,
                    child: TextFormField(
                      controller: _descCtrl,
                      style: fieldStyle,
                      decoration: bare(hint: 'e.g. 30% Advance, 70% in 30 Days'),
                    ),
                  ),
                  const SizedBox(height: 18),

                  Row(children: [
                    const Expanded(child: Text('Installment Lines', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary))),
                    TextButton.icon(onPressed: _addLine, icon: const Icon(Icons.add, size: 16), label: const Text('Add Line')),
                  ]),
                  const SizedBox(height: 6),
                  ..._lines.map((row) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      SizedBox(width: 110, child: DropdownButtonFormField<String>(
                        decoration: const InputDecoration(labelText: 'Type'),
                        isExpanded: true, isDense: true, itemHeight: null,
                        initialValue: row.valueType,
                        items: const [
                          DropdownMenuItem(value: 'PERCENT', child: Text('Percent')),
                          DropdownMenuItem(value: 'FIXED',   child: Text('Fixed')),
                        ],
                        onChanged: (v) => setState(() => row.valueType = v!),
                      )),
                      SizedBox(width: 110, child: TextFormField(
                        controller: row.valueCtrl,
                        textAlign: TextAlign.right,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(labelText: row.valueType == 'PERCENT' ? 'Percent' : 'Amount'),
                      )),
                      SizedBox(width: 100, child: TextFormField(
                        controller: row.dueDaysCtrl,
                        textAlign: TextAlign.right,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Due Days'),
                      )),
                      SizedBox(
                        width: 150,
                        child: CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: const Text('End of Month', style: TextStyle(fontSize: 12)),
                          value: row.isEndOfMonth,
                          onChanged: (v) => setState(() => row.isEndOfMonth = v ?? false),
                        ),
                      ),
                      if (_lines.length > 1) IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.negative),
                        onPressed: () => _removeLine(row),
                      ),
                    ]),
                  )),
                  const SizedBox(height: 6),
                  const Text('If every line is Percent, they must sum to 100%.',
                      style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                  const SizedBox(height: 14),

                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Active', style: TextStyle(fontSize: 14)),
                    value: _isActive,
                    onChanged: (v) => setState(() => _isActive = v),
                    activeThumbColor: AppColors.positive,
                  ),
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
                            : Text(_isEdit ? 'Save Changes' : 'Add Term'),
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
