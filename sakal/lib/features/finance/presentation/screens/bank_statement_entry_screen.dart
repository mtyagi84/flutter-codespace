import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:csv/csv.dart';
import 'package:excel/excel.dart' as xls;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/layout/screen_header.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/reporting/web_download.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../core/utils/deferred_row_disposal.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/sakal_field_row.dart';
import '../../../../core/widgets/sakal_table_header_bar.dart';
import '../../data/bank_statement_parser.dart';

/// Canonical column order for a downloadable template — mirrors
/// _mappingKeys in bank_statement_format_screen.dart so a generated
/// template reads in the same left-to-right order a user would see in the
/// Format Master's own entry dialog.
const _templateColumnOrder = ['serial_no', 'txn_no', 'txn_date', 'remarks', 'debit', 'credit', 'running_balance'];

class _LineRow implements DisposableRow {
  int? serialNo;
  final TextEditingController txnNoCtrl;
  DateTime? txnDate;
  final TextEditingController remarksCtrl;
  final TextEditingController debitCtrl;
  final TextEditingController creditCtrl;
  final TextEditingController balanceCtrl;
  bool isReviewed;

  _LineRow({
    this.serialNo,
    String txnNo = '',
    this.txnDate,
    String remarks = '',
    double debit = 0,
    double credit = 0,
    double? balance,
    required this.isReviewed,
  })  : txnNoCtrl = TextEditingController(text: txnNo),
        remarksCtrl = TextEditingController(text: remarks),
        debitCtrl = TextEditingController(text: debit == 0 ? '' : debit.toStringAsFixed(2)),
        creditCtrl = TextEditingController(text: credit == 0 ? '' : credit.toStringAsFixed(2)),
        balanceCtrl = TextEditingController(text: balance == null ? '' : balance.toStringAsFixed(2));

  factory _LineRow.fromParsed(ParsedStatementLine p) => _LineRow(
        txnNo: p.txnNo, txnDate: p.txnDate, remarks: p.remarks,
        debit: p.debitAmount, credit: p.creditAmount, balance: p.runningBalance,
        isReviewed: p.isReviewed,
      );

  @override
  void dispose() {
    txnNoCtrl.dispose();
    remarksCtrl.dispose();
    debitCtrl.dispose();
    creditCtrl.dispose();
    balanceCtrl.dispose();
  }
}

/// Bank Statement entry — upload a bank's own statement (CSV/Excel/PDF),
/// parse it client-side via BankStatementParser using the account's own
/// Format Master, review/correct PDF-sourced rows, Save Draft / Approve.
/// See docs/screens/bank_statement_upload_review.md for the full
/// requirement doc.
class BankStatementEntryScreen extends ConsumerStatefulWidget {
  final String? statementNo;
  final String? statementDate;

  const BankStatementEntryScreen({super.key, this.statementNo, this.statementDate});

  @override
  ConsumerState<BankStatementEntryScreen> createState() => _BankStatementEntryScreenState();
}

class _BankStatementEntryScreenState extends ConsumerState<BankStatementEntryScreen>
    with ScreenPermissionMixin<BankStatementEntryScreen>, ScreenHeaderMixin<BankStatementEntryScreen>,
        DeferredRowDisposal<BankStatementEntryScreen> {
  @override String get screenName => RouteNames.bankStatements;

  bool get _isNew => widget.statementNo == null;

  List<Map<String, dynamic>> _bankAccounts = [];
  List<Map<String, dynamic>> _formats = [];
  String? _bankAccountId;
  String? _formatId;
  DateTime? _periodFrom;
  DateTime? _periodTo;
  final _openingCtrl = TextEditingController(text: '0');
  final _closingCtrl = TextEditingController(text: '0');
  String _sourceFileType = 'CSV';
  String _status = 'DRAFT';

  final List<_LineRow> _lines = [];
  bool _loading = true;
  bool _saving = false;
  bool _parsing = false;
  String? _actionError;
  String? _parseResultMessage;
  bool _parseResultIsWarning = false;

  @override
  ScreenHeaderInfo buildScreenHeader() => ScreenHeaderInfo(
        title: _isNew ? 'New Bank Statement' : 'Bank Statement · ${widget.statementNo}',
        subtitle: _isNew ? 'Unsaved draft' : null,
        badgeText: _status != 'DRAFT' ? _status : null,
        badgeColor: _status == 'APPROVED' ? AppColors.positive : AppColors.secondary,
      );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _openingCtrl.dispose();
    _closingCtrl.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    disposeDeferredRows();
    super.dispose();
  }

  Future<void> _init() async {
    final session = ref.read(sessionProvider)!;
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        DioClient.instance.get('/rim_bank_accounts', queryParameters: {
          'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
          'is_active': 'eq.true', 'is_deleted': 'eq.false',
          'select': 'id,bank_name,default_format_id,account:rim_accounts!account_id(account_code,account_name)',
          'order': 'bank_name.asc',
        }),
        DioClient.instance.get('/rim_bank_statement_formats', queryParameters: {
          'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
          'is_active': 'eq.true', 'is_deleted': 'eq.false',
          'select': 'id,format_name,file_type,header_skip_rows,column_mapping,date_format',
          'order': 'format_name.asc',
        }),
      ]);
      _bankAccounts = List<Map<String, dynamic>>.from(results[0].data as List);
      _formats = List<Map<String, dynamic>>.from(results[1].data as List);

      if (!_isNew) {
        await _loadExisting();
      }
    } catch (e, st) {
      AppLogger.error('BankStatementEntryInit', e, st);
      if (mounted) setState(() => _actionError = ErrorPresenter.format(e, action: 'load this statement'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadExisting() async {
    final session = ref.read(sessionProvider)!;
    final headerRes = await DioClient.instance.get('/rih_bank_statement_headers', queryParameters: {
      'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
      'statement_no': 'eq.${widget.statementNo}', 'statement_date': 'eq.${widget.statementDate}',
      'select': '*',
    });
    if ((headerRes.data as List).isEmpty) return;
    final h = (headerRes.data as List).first as Map<String, dynamic>;

    _bankAccountId = h['bank_account_id'] as String?;
    _periodFrom = DateTime.tryParse(h['period_from'] as String? ?? '');
    _periodTo = DateTime.tryParse(h['period_to'] as String? ?? '');
    _openingCtrl.text = (h['opening_balance'] as num? ?? 0).toString();
    _closingCtrl.text = (h['closing_balance'] as num? ?? 0).toString();
    _sourceFileType = h['source_file_type'] as String? ?? 'CSV';
    _status = h['status'] as String? ?? 'DRAFT';

    final linesRes = await DioClient.instance.get('/rid_bank_statement_lines', queryParameters: {
      'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
      'statement_no': 'eq.${widget.statementNo}', 'statement_date': 'eq.${widget.statementDate}',
      'is_deleted': 'eq.false', 'select': '*', 'order': 'serial_no.asc',
    });
    for (final j in (linesRes.data as List)) {
      final m = j as Map<String, dynamic>;
      _lines.add(_LineRow(
        serialNo: (m['serial_no'] as num).toInt(),
        txnNo: m['txn_no'] as String? ?? '',
        txnDate: DateTime.tryParse(m['txn_date'] as String? ?? ''),
        remarks: m['remarks'] as String? ?? '',
        debit: (m['debit_amount'] as num? ?? 0).toDouble(),
        credit: (m['credit_amount'] as num? ?? 0).toDouble(),
        balance: (m['running_balance'] as num?)?.toDouble(),
        isReviewed: m['is_reviewed'] as bool? ?? true,
      ));
    }
  }

  Map<String, dynamic>? get _selectedFormat =>
      _formats.where((f) => f['id'] == _formatId).cast<Map<String, dynamic>?>().firstOrNull;

  Future<void> _pickAndParseFile() async {
    if (_bankAccountId == null) {
      _showSnack('Select a Bank Account first.', color: AppColors.negative);
      return;
    }
    if (_formatId == null) {
      _showSnack('Select a Statement Format first.', color: AppColors.negative);
      return;
    }
    final format = _selectedFormat;
    if (format == null) return;

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom, allowedExtensions: ['csv', 'xlsx', 'pdf'], withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      _showSnack('Could not read the selected file.', color: AppColors.negative);
      return;
    }

    setState(() {
      _parsing = true;
      _parseResultMessage = null;
    });
    try {
      final fileType = format['file_type'] as String;
      final headerSkipRows = (format['header_skip_rows'] as num? ?? 0).toInt();
      final columnMapping = (format['column_mapping'] as Map<String, dynamic>? ?? {});
      final dateFormat = format['date_format'] as String? ?? 'DD/MM/YYYY';

      // Heavy parsing (esp. PDF text extraction) is synchronous/CPU-bound —
      // run it on a background isolate via compute() so the main isolate
      // stays free to actually paint the "Parsing…" spinner above, rather
      // than blocking the whole UI thread with no visible feedback.
      List<ParsedStatementLine> parsed;
      switch (fileType) {
        case 'EXCEL':
          parsed = await compute(parseExcelIsolate, CsvOrExcelParseParams(
              bytes: Uint8List.fromList(bytes), headerSkipRows: headerSkipRows,
              columnMapping: columnMapping, dateFormat: dateFormat));
          break;
        case 'PDF':
          parsed = await compute(parsePdfIsolate, CsvOrExcelParseParams(
              bytes: Uint8List.fromList(bytes), headerSkipRows: headerSkipRows,
              columnMapping: columnMapping, dateFormat: dateFormat));
          break;
        case 'CSV':
        default:
          parsed = await compute(parseCsvIsolate, CsvOrExcelParseParams(
              csvContent: String.fromCharCodes(bytes), headerSkipRows: headerSkipRows,
              columnMapping: columnMapping, dateFormat: dateFormat));
      }

      if (!mounted) return;

      if (parsed.isEmpty) {
        setState(() {
          _parseResultMessage = 'No transaction rows were found in this file — check the Format Master\'s header-skip row count and column mapping, then try again.';
          _parseResultIsWarning = true;
        });
        return;
      }

      final unreviewedCount = parsed.where((p) => !p.isReviewed).length;
      setState(() {
        for (final l in _lines) {
          deferRowDisposal(l);
        }
        _lines
          ..clear()
          ..addAll(parsed.map(_LineRow.fromParsed));
        _sourceFileType = fileType;
        _parseResultIsWarning = unreviewedCount > 0;
        _parseResultMessage = unreviewedCount > 0
            ? 'Extracted ${parsed.length} line(s) — $unreviewedCount need review (PDF-extracted, marked below) before this statement can be approved.'
            : 'Extracted ${parsed.length} line(s) successfully.';
      });
    } catch (e, st) {
      AppLogger.error('BankStatementParse', e, st);
      if (mounted) {
        setState(() {
          _parseResultMessage = ErrorPresenter.format(e, action: 'parse this file');
          _parseResultIsWarning = true;
        });
      }
    } finally {
      if (mounted) setState(() => _parsing = false);
    }
  }

  /// Fallback for when PDF/Excel extraction doesn't work for a given
  /// statement: generates a blank CSV/Excel file whose header row is built
  /// from THIS format's own column_mapping (the exact text
  /// _resolveHeaderIndexes will match against on re-upload, not a
  /// hardcoded label), so the user can fill it in by hand (or copy values
  /// from the bank's PDF/portal) and upload it back through the normal,
  /// far more reliable CSV/EXCEL parse path. Never offered for a PDF-type
  /// format — its column_mapping values are column ORDER numbers, not
  /// header text, so there's no meaningful header row to generate.
  Future<void> _downloadTemplate() async {
    final format = _selectedFormat;
    if (format == null) return;
    final fileType = format['file_type'] as String;
    if (fileType == 'PDF') return;

    final columnMapping = (format['column_mapping'] as Map<String, dynamic>? ?? {});
    final headerSkipRows = (format['header_skip_rows'] as num? ?? 0).toInt();
    final headers = _templateColumnOrder
        .map((k) => columnMapping[k]?.toString().trim())
        .where((v) => v != null && v.isNotEmpty)
        .cast<String>()
        .toList();
    if (headers.isEmpty) {
      _showSnack('This format has no column mapping configured yet — set it up in Bank Statement Formats first.', color: AppColors.negative);
      return;
    }

    final formatName = (format['format_name'] as String? ?? 'statement').replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_').toLowerCase();

    if (fileType == 'EXCEL') {
      final workbook = xls.Excel.createExcel();
      final sheetName = workbook.getDefaultSheet()!;
      final sheet = workbook[sheetName];
      for (var i = 0; i < headerSkipRows; i++) {
        sheet.appendRow(List.generate(headers.length, (_) => xls.TextCellValue('')));
      }
      sheet.appendRow(headers.map((h) => xls.TextCellValue(h)).toList());
      final bytes = workbook.encode();
      if (bytes == null) return;
      await _saveTemplateBytes(bytes, '${formatName}_template.xlsx', 'xlsx', 'Save $formatName template');
    } else {
      final rows = <List<String>>[
        for (var i = 0; i < headerSkipRows; i++) List.generate(headers.length, (_) => ''),
        headers,
      ];
      final csvString = const ListToCsvConverter(eol: '\n').convert(rows);
      await _saveTemplateBytes(utf8.encode(csvString), '${formatName}_template.csv', 'csv', 'Save $formatName template');
    }
  }

  /// FilePicker.platform.saveFile() goes through Chrome's File System
  /// Access API on web, which requires a still-valid "user activation" —
  /// timing-sensitive enough that it can silently fail. Same fix already
  /// proven in report_excel_export.dart / opening_stock_entry_screen.dart:
  /// a Blob+anchor download on web, FilePicker unchanged elsewhere.
  Future<void> _saveTemplateBytes(List<int> bytes, String filename, String extension, String dialogTitle) async {
    if (kIsWeb) {
      downloadBytesOnWeb(bytes, filename);
      return;
    }
    await FilePicker.platform.saveFile(
      dialogTitle: dialogTitle,
      fileName: filename,
      bytes: Uint8List.fromList(bytes),
      type: FileType.custom, allowedExtensions: [extension],
    );
  }

  void _addBlankLine() {
    setState(() => _lines.add(_LineRow(isReviewed: true)));
  }

  void _removeLine(_LineRow row) {
    setState(() => _lines.remove(row));
    deferRowDisposal(row);
  }

  void _showSnack(String msg, {required Color color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  bool get _hasUnreviewedLines => _lines.any((l) => !l.isReviewed);

  Future<void> _save({bool andApprove = false}) async {
    if (_bankAccountId == null || _periodFrom == null || _periodTo == null) {
      _showSnack('Fill in Bank Account and Period before saving.', color: AppColors.negative);
      return;
    }
    if (_lines.isEmpty) {
      _showSnack('Upload a statement or add at least one line.', color: AppColors.negative);
      return;
    }
    final session = ref.read(sessionProvider)!;
    if (session.locationId == null) {
      _showSnack('No location is set on your session — contact an administrator.', color: AppColors.negative);
      return;
    }

    setState(() { _saving = true; _actionError = null; });
    try {
      final header = {
        'client_id': session.clientId,
        'company_id': session.companyId,
        'location_id': session.locationId!,
        if (!_isNew) 'statement_no': widget.statementNo,
        'statement_date': (_isNew ? DateTime.now() : DateTime.parse(widget.statementDate!)).toIso8601String().split('T').first,
        'bank_account_id': _bankAccountId,
        'period_from': _periodFrom!.toIso8601String().split('T').first,
        'period_to': _periodTo!.toIso8601String().split('T').first,
        'source_file_type': _sourceFileType,
        'opening_balance': double.tryParse(_openingCtrl.text.trim()) ?? 0,
        'closing_balance': double.tryParse(_closingCtrl.text.trim()) ?? 0,
      };

      final lines = _lines.asMap().entries.map((e) => {
            'serial_no': e.key + 1,
            'txn_no': e.value.txnNoCtrl.text.trim(),
            'txn_date': (e.value.txnDate ?? DateTime.now()).toIso8601String().split('T').first,
            'remarks': e.value.remarksCtrl.text.trim(),
            'debit_amount': double.tryParse(e.value.debitCtrl.text.trim()) ?? 0,
            'credit_amount': double.tryParse(e.value.creditCtrl.text.trim()) ?? 0,
            'running_balance': double.tryParse(e.value.balanceCtrl.text.trim()),
            'is_reviewed': e.value.isReviewed,
          }).toList();

      final res = await DioClient.instance.post('/rpc/fn_save_bank_statement', data: {
        'p_header': header, 'p_lines': lines, 'p_user_id': session.userId,
      });
      final savedNo = res.data as String;

      if (andApprove) {
        await DioClient.instance.post('/rpc/fn_approve_bank_statement', data: {
          'p_client_id': session.clientId, 'p_company_id': session.companyId,
          'p_statement_no': savedNo, 'p_statement_date': header['statement_date'],
          'p_approved_by': session.userId,
        });
      }

      if (mounted) {
        _showSnack(andApprove ? 'Bank Statement approved.' : 'Bank Statement saved.', color: AppColors.positive);
        Navigator.of(context).pop(true);
      }
    } catch (e, st) {
      AppLogger.error('BankStatementSave', e, st);
      if (mounted) setState(() => _actionError = ErrorPresenter.format(e, action: 'save this statement'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<DateTime?> _pickDate(DateTime? initial) => showDatePicker(
        context: context, initialDate: initial ?? DateTime.now(),
        firstDate: DateTime(2020), lastDate: DateTime(2100),
      );

  @override
  Widget build(BuildContext context) {
    refreshScreenHeader();
    if (_loading) return const Center(child: CircularProgressIndicator());

    final canEditNow = _status == 'DRAFT' && canEdit;
    final isMobile = Responsive.isMobile(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_actionError != null)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: AppColors.negative.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
            child: Text(_actionError!, style: const TextStyle(color: AppColors.negative, fontSize: 12)),
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SakalFieldRow(isMobile: isMobile, children: [
                DropdownButtonFormField<String>(
                  initialValue: _bankAccountId,
                  isExpanded: true, isDense: true, itemHeight: null,
                  decoration: const InputDecoration(labelText: 'Bank Account *'),
                  items: _bankAccounts.map((a) {
                    final account = a['account'] as Map<String, dynamic>?;
                    return DropdownMenuItem(
                      value: a['id'] as String,
                      child: Text('${a['bank_name']} — [${account?['account_code']}] ${account?['account_name']}', overflow: TextOverflow.ellipsis),
                    );
                  }).toList(),
                  onChanged: canEditNow ? (v) => setState(() {
                    _bankAccountId = v;
                    final acct = _bankAccounts.firstWhere((a) => a['id'] == v, orElse: () => {});
                    _formatId = acct['default_format_id'] as String?;
                  }) : null,
                ),
                DropdownButtonFormField<String>(
                  initialValue: _formatId,
                  isExpanded: true, isDense: true, itemHeight: null,
                  decoration: const InputDecoration(labelText: 'Statement Format *'),
                  items: _formats.map((f) => DropdownMenuItem(value: f['id'] as String, child: Text('${f['format_name']} (${f['file_type']})', overflow: TextOverflow.ellipsis))).toList(),
                  onChanged: canEditNow ? (v) => setState(() => _formatId = v) : null,
                ),
              ]),
              const SizedBox(height: 10),
              SakalFieldRow(isMobile: isMobile, children: [
                _dateField('Period From *', _periodFrom, canEditNow, (d) => setState(() => _periodFrom = d)),
                _dateField('Period To *', _periodTo, canEditNow, (d) => setState(() => _periodTo = d)),
              ]),
              const SizedBox(height: 10),
              SakalFieldRow(isMobile: isMobile, children: [
                TextFormField(controller: _openingCtrl, enabled: canEditNow, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Opening Balance')),
                TextFormField(controller: _closingCtrl, enabled: canEditNow, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Closing Balance (per Bank)')),
              ]),
              if (canEditNow) ...[
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  FilledButton.icon(
                    onPressed: _parsing ? null : _pickAndParseFile,
                    icon: _parsing ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.upload_file, size: 16),
                    label: Text(_parsing ? 'Parsing…' : 'Upload Statement File (CSV / Excel / PDF)'),
                  ),
                  Tooltip(
                    message: (_selectedFormat?['file_type'] == 'PDF')
                        ? "PDF formats don't have a fill-in template — pick or create a CSV/Excel Format for manual entry."
                        : 'If extraction fails or looks wrong, download a blank file matching this format\'s columns, fill it in by hand, and upload it back.',
                    child: OutlinedButton.icon(
                      onPressed: (_formatId == null || _selectedFormat?['file_type'] == 'PDF') ? null : _downloadTemplate,
                      icon: const Icon(Icons.download, size: 16),
                      label: const Text('Download Template'),
                    ),
                  ),
                ]),
              ],
            ]),
          ),
        ),
        const SizedBox(height: 14),
        if (_parseResultMessage != null)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: (_parseResultIsWarning ? AppColors.secondary : AppColors.positive).withValues(alpha: 0.08),
              border: Border.all(color: (_parseResultIsWarning ? AppColors.secondary : AppColors.positive).withValues(alpha: 0.4)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(children: [
              Icon(_parseResultIsWarning ? Icons.warning_amber_rounded : Icons.check_circle_outline, size: 16, color: _parseResultIsWarning ? AppColors.secondary : AppColors.positive),
              const SizedBox(width: 8),
              Expanded(child: Text(_parseResultMessage!, style: TextStyle(fontSize: 12, color: _parseResultIsWarning ? AppColors.secondary : AppColors.positive))),
              IconButton(icon: const Icon(Icons.close, size: 14), onPressed: () => setState(() => _parseResultMessage = null), tooltip: 'Dismiss'),
            ]),
          ),
        Row(children: [
          Text('Statement Lines${_lines.isNotEmpty ? ' (${_lines.length})' : ''}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          const Spacer(),
          if (canEditNow) TextButton.icon(onPressed: _addBlankLine, icon: const Icon(Icons.add, size: 16), label: const Text('Add Line')),
        ]),
        const SizedBox(height: 8),
        if (_lines.isEmpty)
          const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Center(child: Text('No lines yet — upload a statement file above.', style: TextStyle(color: AppColors.textSecondary)))),
        if (_lines.isNotEmpty)
          isMobile
              ? Column(children: _lines.map((row) => _buildLineCard(row, canEditNow, isMobile)).toList())
              : _buildLinesTable(canEditNow),
        const SizedBox(height: 20),
        if (canEditNow)
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _saving ? null : () => _save(),
                child: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save Draft'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Tooltip(
                message: _hasUnreviewedLines ? 'All PDF-extracted lines must be reviewed before approving.' : '',
                child: FilledButton(
                  onPressed: (_saving || _hasUnreviewedLines) ? null : () => _save(andApprove: true),
                  child: const Text('Save & Approve'),
                ),
              ),
            ),
          ]),
      ]),
    );
  }

  Widget _dateField(String label, DateTime? value, bool enabled, ValueChanged<DateTime?> onChanged) {
    return InkWell(
      onTap: enabled ? () async => onChanged(await _pickDate(value)) : null,
      child: InputDecorator(
        decoration: InputDecoration(labelText: label),
        child: Text(value == null ? '—' : '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}'),
      ),
    );
  }

  static const List<(String, double)> _tableCols = [
    ('SR', 40),
    ('TXN NO', 110),
    ('DATE', 130),
    ('REMARKS', 300),
    ('DEBIT', 110),
    ('CREDIT', 110),
    ('BALANCE', 110),
    ('STATUS / ACTIONS', 170),
  ];

  double get _tableWidth => _tableCols.fold(0.0, (sum, c) => sum + c.$2);

  /// Desktop-only tabular rendering of the line list — a per-line "small
  /// form" card (still used on mobile, see _buildLineCard) is unusable once
  /// a statement has 250+ lines (a real user report: unmanageable to scroll
  /// and review). One SakalTableHeaderBar + a virtualized ListView.builder,
  /// fixed-height with its own vertical scroll, wrapped in a horizontal
  /// scroll for narrower desktop widths — per CLAUDE.md's documented
  /// "SakalTableHeaderBar (desktop) + SakalLineItemCard (mobile)" rule.
  Widget _buildLinesTable(bool canEditNow) {
    return Scrollbar(
      thumbVisibility: true,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: _tableWidth,
          height: 560,
          child: Column(children: [
            SakalTableHeaderBar(cells: _tableCols.map((c) => SizedBox(width: c.$2, child: SakalTableHeaderBar.label(c.$1))).toList()),
            Expanded(
              child: Container(
                decoration: BoxDecoration(border: Border.all(color: AppColors.border), borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10))),
                child: ListView.builder(
                  itemCount: _lines.length,
                  itemBuilder: (context, index) => _buildLineTableRow(_lines[index], index, canEditNow),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildLineTableRow(_LineRow row, int index, bool canEditNow) {
    final needsReview = !row.isReviewed;
    Widget cell(double width, Widget child) => SizedBox(width: width, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6), child: child));
    InputDecoration dec() => const InputDecoration(isDense: true, border: InputBorder.none, contentPadding: EdgeInsets.symmetric(vertical: 4));

    return Container(
      decoration: BoxDecoration(
        color: needsReview ? AppColors.secondary.withValues(alpha: 0.08) : (index.isEven ? Colors.white : AppColors.background),
        border: const Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        cell(_tableCols[0].$2, Text('${index + 1}', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))),
        cell(_tableCols[1].$2, TextFormField(controller: row.txnNoCtrl, enabled: canEditNow, style: const TextStyle(fontSize: 12), decoration: dec())),
        cell(_tableCols[2].$2, InkWell(
          onTap: canEditNow ? () async { final d = await _pickDate(row.txnDate); if (d != null) setState(() => row.txnDate = d); } : null,
          child: Text(row.txnDate == null ? '—' : '${row.txnDate!.year}-${row.txnDate!.month.toString().padLeft(2, '0')}-${row.txnDate!.day.toString().padLeft(2, '0')}', style: const TextStyle(fontSize: 12)),
        )),
        cell(_tableCols[3].$2, TextFormField(controller: row.remarksCtrl, enabled: canEditNow, maxLines: 1, style: const TextStyle(fontSize: 12), decoration: dec())),
        cell(_tableCols[4].$2, TextFormField(controller: row.debitCtrl, enabled: canEditNow, keyboardType: TextInputType.number, style: const TextStyle(fontSize: 12), decoration: dec())),
        cell(_tableCols[5].$2, TextFormField(controller: row.creditCtrl, enabled: canEditNow, keyboardType: TextInputType.number, style: const TextStyle(fontSize: 12), decoration: dec())),
        cell(_tableCols[6].$2, TextFormField(controller: row.balanceCtrl, enabled: canEditNow, keyboardType: TextInputType.number, style: const TextStyle(fontSize: 12), decoration: dec())),
        cell(_tableCols[7].$2, Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 2, children: [
          if (needsReview)
            needsReview && canEditNow
                ? TextButton(
                    onPressed: () => setState(() => row.isReviewed = true),
                    style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    child: const Text('Mark Reviewed', style: TextStyle(fontSize: 11)),
                  )
                : const Icon(Icons.warning_amber_rounded, size: 14, color: AppColors.secondary),
          if (canEditNow)
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 15),
              padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              visualDensity: VisualDensity.compact,
              onPressed: () => _removeLine(row), tooltip: 'Remove',
            ),
        ])),
      ]),
    );
  }

  Widget _buildLineCard(_LineRow row, bool canEditNow, bool isMobile) {
    final needsReview = !row.isReviewed;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: needsReview ? AppColors.secondary.withValues(alpha: 0.08) : AppColors.surface,
        border: Border.all(color: needsReview ? AppColors.secondary : AppColors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (needsReview)
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Row(children: [
              Icon(Icons.warning_amber_rounded, size: 14, color: AppColors.secondary),
              SizedBox(width: 4),
              Text('Extracted from PDF — please verify', style: TextStyle(fontSize: 11, color: AppColors.secondary, fontWeight: FontWeight.w600)),
            ]),
          ),
        SakalFieldRow(isMobile: isMobile, children: [
          TextFormField(controller: row.txnNoCtrl, enabled: canEditNow, decoration: const InputDecoration(labelText: 'Txn No')),
          _dateField('Date', row.txnDate, canEditNow, (d) => setState(() => row.txnDate = d)),
        ]),
        const SizedBox(height: 8),
        TextFormField(controller: row.remarksCtrl, enabled: canEditNow, decoration: const InputDecoration(labelText: 'Remarks')),
        const SizedBox(height: 8),
        SakalFieldRow(isMobile: isMobile, children: [
          TextFormField(controller: row.debitCtrl, enabled: canEditNow, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Debit')),
          TextFormField(controller: row.creditCtrl, enabled: canEditNow, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Credit')),
          TextFormField(controller: row.balanceCtrl, enabled: canEditNow, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Balance')),
        ]),
        if (canEditNow)
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            if (needsReview)
              TextButton.icon(
                onPressed: () => setState(() => row.isReviewed = true),
                icon: const Icon(Icons.check, size: 14),
                label: const Text('Mark Reviewed'),
              ),
            IconButton(icon: const Icon(Icons.delete_outline, size: 16), onPressed: () => _removeLine(row), tooltip: 'Remove'),
          ]),
      ]),
    );
  }
}
