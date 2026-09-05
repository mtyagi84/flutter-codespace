import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/layout/screen_header.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/sakal_adaptive_list.dart';

/// One row per bank's own statement column layout. No repository/model
/// layer for this screen (direct DioClient calls), same convention as
/// sales_executive_master_screen.dart — small, self-contained master.
class BankStatementFormat {
  final String id;
  final String formatName;
  final String fileType; // CSV / EXCEL / PDF
  final int headerSkipRows;
  final Map<String, dynamic> columnMapping;
  final String dateFormat;
  final bool isActive;

  const BankStatementFormat({
    required this.id,
    required this.formatName,
    required this.fileType,
    required this.headerSkipRows,
    required this.columnMapping,
    required this.dateFormat,
    required this.isActive,
  });

  factory BankStatementFormat.fromJson(Map<String, dynamic> j) => BankStatementFormat(
        id:             j['id'] as String? ?? '',
        formatName:     j['format_name'] as String? ?? '',
        fileType:       j['file_type'] as String? ?? 'CSV',
        headerSkipRows: (j['header_skip_rows'] as num?)?.toInt() ?? 0,
        columnMapping:  (j['column_mapping'] as Map<String, dynamic>?) ?? const {},
        dateFormat:     j['date_format'] as String? ?? 'DD/MM/YYYY',
        isActive:       j['is_active'] as bool? ?? true,
      );
}

const _mappingKeys = <String, String>{
  'serial_no': 'Serial No (as printed, optional — helps count PDF columns correctly)',
  'txn_no': 'Transaction No',
  'txn_date': 'Transaction Date',
  'remarks': 'Remarks',
  'debit': 'Debit',
  'credit': 'Credit',
  'running_balance': 'Running Balance',
};

const _dateFormats = ['DD/MM/YYYY', 'DD-MM-YYYY', 'MM/DD/YYYY', 'YYYY-MM-DD'];
const _fileTypes = ['CSV', 'EXCEL', 'PDF'];

/// Bank Statement Format Master (migration 174) — tells the Upload &
/// Review screen how to read a bank's own statement layout: which
/// row/column holds Transaction No/Date/Remarks/Debit/Credit/Running
/// Balance, how many header rows to skip, and the date format that bank
/// uses. Configured once per bank, reused on every upload. For CSV/EXCEL
/// each mapping value is the SOURCE COLUMN HEADER NAME as printed on the
/// statement; for PDF it's the column ORDER (1st, 2nd, 3rd…) since a PDF
/// has no reliable header text to key off.
class BankStatementFormatScreen extends ConsumerStatefulWidget {
  const BankStatementFormatScreen({super.key});

  @override
  ConsumerState<BankStatementFormatScreen> createState() => _BankStatementFormatScreenState();
}

class _BankStatementFormatScreenState extends ConsumerState<BankStatementFormatScreen>
    with ScreenPermissionMixin<BankStatementFormatScreen>, ScreenHeaderMixin<BankStatementFormatScreen> {
  @override String get screenName => RouteNames.bankStatementFormats;

  @override
  ScreenHeaderInfo buildScreenHeader() => ScreenHeaderInfo(
        title: 'Bank Statement Formats',
        actions: canAdd
            ? [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilledButton.icon(
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('New Format'),
                    onPressed: () => _showEntryDialog(),
                  ),
                ),
              ]
            : const [],
      );

  List<BankStatementFormat> _rows = [];
  bool _loading = true;
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
      final res = await DioClient.instance.get('/rim_bank_statement_formats', queryParameters: {
        'client_id': 'eq.${session.clientId}',
        'company_id': 'eq.${session.companyId}',
        'is_deleted': 'eq.false',
        'select': '*',
        'order': 'format_name.asc',
      });
      if (mounted) {
        setState(() {
          _rows = (res.data as List).map((j) => BankStatementFormat.fromJson(j as Map<String, dynamic>)).toList();
          _loading = false;
        });
      }
    } on DioException {
      if (mounted) setState(() { _loading = false; _error = 'Could not load bank statement formats.'; });
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: AppColors.negative));
  }

  Future<void> _save(Map<String, dynamic> payload, {String? id}) async {
    final session = ref.read(sessionProvider)!;
    try {
      if (id == null) {
        await DioClient.instance.post('/rim_bank_statement_formats', data: {...payload, 'created_by': session.userId});
      } else {
        await DioClient.instance.patch('/rim_bank_statement_formats',
            queryParameters: {'id': 'eq.$id'}, data: {...payload, 'updated_by': session.userId});
      }
      await _load();
    } on DioException catch (e) {
      _showError(e.response?.data?['message'] ?? 'Save failed.');
    }
  }

  Future<void> _toggleActive(BankStatementFormat row) async {
    final session = ref.read(sessionProvider)!;
    try {
      await DioClient.instance.patch('/rim_bank_statement_formats',
          queryParameters: {'id': 'eq.${row.id}'},
          data: {'is_active': !row.isActive, 'updated_by': session.userId});
      await _load();
    } on DioException catch (e) {
      _showError(e.response?.data?['message'] ?? 'Update failed.');
    }
  }

  Future<void> _showEntryDialog({BankStatementFormat? existing}) async {
    final nameCtrl = TextEditingController(text: existing?.formatName ?? '');
    final skipCtrl = TextEditingController(text: (existing?.headerSkipRows ?? 0).toString());
    String fileType = existing?.fileType ?? 'CSV';
    String dateFormat = existing?.dateFormat ?? 'DD/MM/YYYY';
    final mappingCtrls = {
      for (final k in _mappingKeys.keys)
        k: TextEditingController(text: existing?.columnMapping[k]?.toString() ?? ''),
    };

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'New Bank Statement Format' : 'Edit Bank Statement Format'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Format Name * (e.g. HDFC Bank)')),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: fileType,
                  isExpanded: true, isDense: true, itemHeight: null,
                  decoration: const InputDecoration(labelText: 'File Type *'),
                  items: _fileTypes.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                  onChanged: (v) => setDialogState(() => fileType = v ?? fileType),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: skipCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Header Rows to Skip'),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: dateFormat,
                  isExpanded: true, isDense: true, itemHeight: null,
                  decoration: const InputDecoration(labelText: 'Date Format on Statement *'),
                  items: _dateFormats.map((d) => DropdownMenuItem(value: d, child: Text(d))).toList(),
                  onChanged: (v) => setDialogState(() => dateFormat = v ?? dateFormat),
                ),
                const SizedBox(height: 14),
                Text(
                  fileType == 'PDF'
                      ? 'Column Mapping — enter the COLUMN ORDER (1, 2, 3…) as it appears in the PDF table:'
                      : 'Column Mapping — enter the exact column HEADER NAME as printed on the statement:',
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 8),
                ..._mappingKeys.entries.map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: TextField(
                        controller: mappingCtrls[e.key],
                        decoration: InputDecoration(labelText: e.value),
                      ),
                    )),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(true), child: const Text('Save')),
          ],
        ),
      ),
    );

    if (saved == true && nameCtrl.text.trim().isNotEmpty) {
      final session = ref.read(sessionProvider)!;
      await _save({
        'client_id': session.clientId,
        'company_id': session.companyId,
        'format_name': nameCtrl.text.trim(),
        'file_type': fileType,
        'header_skip_rows': int.tryParse(skipCtrl.text.trim()) ?? 0,
        'date_format': dateFormat,
        'column_mapping': {
          for (final k in _mappingKeys.keys)
            if (mappingCtrls[k]!.text.trim().isNotEmpty) k: mappingCtrls[k]!.text.trim(),
        },
      }, id: existing?.id);
    }
    nameCtrl.dispose();
    skipCtrl.dispose();
    for (final c in mappingCtrls.values) {
      c.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    refreshScreenHeader();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
      child: SakalAdaptiveList<BankStatementFormat>(
        loading: _loading,
        error: _error,
        rows: _rows,
        columns: const [
          SakalListColumn('Format Name', flex: 3),
          SakalListColumn('File Type', flex: 2),
          SakalListColumn('Skip Rows', flex: 2),
          SakalListColumn('Status', flex: 2),
          SakalListColumn('', flex: 2),
        ],
        rowBuilder: _buildRow,
        cardBuilder: _buildCard,
        emptyState: _emptyState(),
      ),
    );
  }

  Widget _statusBadge(bool isActive) {
    final color = isActive ? AppColors.positive : AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4), border: Border.all(color: color.withValues(alpha: 0.4))),
      child: Text(isActive ? 'Active' : 'Inactive', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
    );
  }

  Widget _buildRow(BankStatementFormat r, int index) {
    return InkWell(
      onTap: canEdit ? () => _showEntryDialog(existing: r) : null,
      child: Container(
        color: index.isEven ? Colors.white : AppColors.background,
        child: Row(children: [
          Expanded(flex: 3, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Text(r.formatName, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.primary)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(r.fileType, style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('${r.headerSkipRows}', style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _statusBadge(r.isActive))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Wrap(alignment: WrapAlignment.start, spacing: 0, runSpacing: 0, children: [
                if (canEdit) IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _showEntryDialog(existing: r), tooltip: 'Edit'),
                if (canEdit) IconButton(
                    icon: Icon(r.isActive ? Icons.block : Icons.check_circle_outline, size: 16, color: r.isActive ? AppColors.negative : AppColors.positive),
                    padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _toggleActive(r), tooltip: r.isActive ? 'Deactivate' : 'Activate'),
              ]))),
        ]),
      ),
    );
  }

  Widget _buildCard(BankStatementFormat r) {
    return InkWell(
      onTap: canEdit ? () => _showEntryDialog(existing: r) : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(r.formatName, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary))),
            _statusBadge(r.isActive),
          ]),
          const SizedBox(height: 4),
          Text('${r.fileType} · skip ${r.headerSkipRows} header row(s)', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        ]),
      ),
    );
  }

  Widget _emptyState() => const Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.description_outlined, size: 48, color: AppColors.textDisabled),
      SizedBox(height: 16),
      Text('No bank statement formats found', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
      SizedBox(height: 8),
      Text('Define how each bank\'s statement is laid out before uploading one.',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
    ]),
  );
}
