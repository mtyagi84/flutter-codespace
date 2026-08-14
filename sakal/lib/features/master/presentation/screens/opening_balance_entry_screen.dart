import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:excel/excel.dart' as xls;
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/layout/screen_header.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/reporting/web_download.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_presets.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../core/utils/deferred_row_disposal.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/sakal_field_card.dart';
import '../../../../core/widgets/sakal_field_row.dart';
import '../../../../core/widgets/sakal_header_action_button.dart';
import '../../../../core/widgets/sakal_line_item_card.dart';
import '../../../../core/widgets/sakal_scrollable_table.dart';
import '../../../../core/widgets/sakal_table_header_bar.dart';
import '../../../finance/presentation/widgets/finance_account_picker.dart';
import '../providers/opening_balance_providers.dart';

/// Opening Balance worksheet — Chart of Accounts / Finance Masters.
/// No document/status lifecycle (unlike Opening Stock's DRAFT/APPROVED):
/// rid_opening_balance_lines is a plain table, freely editable at any
/// time, one financial year (+ location group under INTER_ENTITY) at a
/// time. Save is a full delete-and-reinsert for that scope. See
/// sakal/docs/screens/plan_opening_balance_entry_screen.md for the full
/// design rationale.
class OpeningBalanceEntryScreen extends ConsumerStatefulWidget {
  const OpeningBalanceEntryScreen({super.key});

  @override
  ConsumerState<OpeningBalanceEntryScreen> createState() => _OpeningBalanceEntryScreenState();
}

class _OBLineRow implements DisposableRow {
  String? accountId;
  String accountDisplay = '';
  // 'Customer'/'Supplier'/'Cash'/'Bank'/'General'/etc. (rim_accounts.account_nature)
  // — gates whether Bill No/Bill Date are editable on this row.
  String accountNature = '';
  // Immediate parent group's account_name — display-only, never uploaded/
  // matched against (Account Code is still the only match key), helps the
  // user identify an account by its group context on-screen and in Excel.
  String groupName = '';
  final baseAmountCtrl = TextEditingController(text: '0');
  final localAmountCtrl = TextEditingController(text: '0');
  final partyAmountCtrl = TextEditingController(text: '0');
  final partyCurrencyCtrl = TextEditingController();
  String obType = 'Dr';
  final invBillNoCtrl = TextEditingController();
  DateTime? invBillDate;
  final accountFocusNode = FocusNode();

  double get baseAmount => double.tryParse(baseAmountCtrl.text) ?? 0;
  double get localAmount => double.tryParse(localAmountCtrl.text) ?? 0;
  double get partyAmount => double.tryParse(partyAmountCtrl.text) ?? 0;

  @override
  void dispose() {
    baseAmountCtrl.dispose();
    localAmountCtrl.dispose();
    partyAmountCtrl.dispose();
    partyCurrencyCtrl.dispose();
    invBillNoCtrl.dispose();
    accountFocusNode.dispose();
  }
}

class _OpeningBalanceEntryScreenState extends ConsumerState<OpeningBalanceEntryScreen>
    with
        ScreenPermissionMixin<OpeningBalanceEntryScreen>,
        ScreenHeaderMixin<OpeningBalanceEntryScreen>,
        DeferredRowDisposal<OpeningBalanceEntryScreen> {
  @override
  String get screenName => '/master/opening-balances';

  bool _loading = false;
  bool _saving = false;
  bool _uploadingExcel = false;
  String? _error;
  String? _actionError;

  String? _fyId;
  // The FY with the earliest fy_start_date — the only one this screen ever
  // allows editing. Later years' opening balances are meant to be
  // auto-generated at FY-closing time (not built yet); until then, picking
  // a later year in the dropdown just shows whatever exists, read-only.
  String? _earliestFyId;
  String? _locationGroupId;
  String _interLocationModel = 'SIMPLE';
  List<Map<String, dynamic>> _accessibleGroups = const [];
  List<Map<String, dynamic>> _financialYears = const [];
  List<Map<String, dynamic>> _postableAccounts = const [];

  bool get _isEditableFy => _fyId != null && _fyId == _earliestFyId;
  bool get _editable => canEdit && _isEditableFy;

  final List<_OBLineRow> _lines = [];
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    disposeDeferredRows();
    _searchCtrl.dispose();
    super.dispose();
  }

  // Client-side filter over already-loaded lines — a company can have
  // thousands of accounts, so a search box is needed to find one to edit
  // without scrolling. Matches on account code/name (from accountDisplay,
  // e.g. "[111001001] Cash USD") or Invoice/Bill No.
  List<_OBLineRow> get _visibleLines {
    if (_searchQuery.isEmpty) return _lines;
    final q = _searchQuery.toLowerCase();
    return _lines.where((l) =>
        l.accountDisplay.toLowerCase().contains(q) ||
        l.invBillNoCtrl.text.toLowerCase().contains(q)).toList();
  }

  Future<void> _init() async {
    setState(() { _loading = true; _error = null; });
    try {
      _interLocationModel = await ref.read(interLocationModelProvider.future);
      if (_interLocationModel == 'INTER_ENTITY') {
        _accessibleGroups = await ref.read(locationGroupsProvider.future);
      }
      _financialYears = await ref.read(financialYearsProvider.future);
      final accounts = await ref.read(accountsProvider.future);
      _postableAccounts = accounts.where((a) => a['posting_allowed'] == true).toList();

      // financialYearsProvider orders fy_start_date DESC — the earliest FY
      // (the only one this screen ever allows editing) is the last entry.
      // ISO date strings ('YYYY-MM-DD') sort correctly as plain strings.
      if (_financialYears.isNotEmpty) {
        final sorted = [..._financialYears]..sort((a, b) => (a['fy_start_date'] as String).compareTo(b['fy_start_date'] as String));
        _earliestFyId = sorted.first['id'] as String;
      }
      // Default to the earliest (editable) year — that's what this screen
      // is for; other years are reachable via the dropdown, view-only.
      _fyId = _earliestFyId ?? (_financialYears.isNotEmpty ? _financialYears.first['id'] as String : null);

      if (_fyId != null) await _loadLines();
      if (mounted) setState(() => _loading = false);
    } catch (e, st) {
      AppLogger.error('OpeningBalanceInit', e, st);
      if (mounted) {
        setState(() {
          _loading = false;
          _error = ErrorPresenter.format(e, action: 'load this screen');
        });
      }
    }
  }

  // Group Name lookup keyed off the already-loaded, already-proven
  // single-level `parent` embed on _postableAccounts (accountsProvider) —
  // see the "single-level embed only" note in OpeningBalanceRemoteDs.getLines().
  String _groupNameForAccount(String? accountId) {
    if (accountId == null) return '';
    for (final a in _postableAccounts) {
      if (a['id'] == accountId) {
        final parent = a['parent'] as Map<String, dynamic>?;
        return parent?['account_name'] as String? ?? '';
      }
    }
    return '';
  }

  Future<void> _loadLines() async {
    if (_fyId == null) return;
    final session = ref.read(sessionProvider)!;
    final repo = ref.read(openingBalanceRepositoryProvider);
    try {
      final rows = await repo.getLines(
        clientId: session.clientId, companyId: session.companyId,
        fyId: _fyId!, locationGroupId: _locationGroupId,
      );
      for (final l in _lines) {
        deferRowDisposal(l);
      }
      final newLines = rows.map((r) {
        final row = _OBLineRow();
        row.accountId = r['account_id'] as String?;
        final acc = r['rim_accounts'] as Map<String, dynamic>?;
        row.accountDisplay = acc != null ? '[${acc['account_code']}] ${acc['account_name']}' : '';
        row.accountNature = acc?['account_nature'] as String? ?? '';
        row.groupName = _groupNameForAccount(row.accountId);
        row.baseAmountCtrl.text = '${r['base_amount'] ?? 0}';
        row.localAmountCtrl.text = '${r['local_amount'] ?? 0}';
        row.partyAmountCtrl.text = '${r['party_amount'] ?? 0}';
        row.partyCurrencyCtrl.text = r['party_currency'] as String? ?? '';
        row.obType = r['ob_type'] as String? ?? 'Dr';
        row.invBillNoCtrl.text = r['inv_bill_no'] as String? ?? '';
        final billDate = r['inv_bill_date'] as String?;
        row.invBillDate = (billDate != null && billDate.isNotEmpty) ? DateTime.tryParse(billDate) : null;
        return row;
      }).toList();
      if (mounted) {
        setState(() {
          _lines
            ..clear()
            ..addAll(newLines);
        });
      }
    } catch (e, st) {
      AppLogger.error('OpeningBalanceLoadLines', e, st);
      if (mounted) setState(() => _actionError = ErrorPresenter.format(e, action: 'load opening balance lines'));
    }
  }

  void _addLine() {
    setState(() => _lines.add(_OBLineRow()));
  }

  void _removeLine(_OBLineRow row) {
    setState(() => _lines.remove(row));
    deferRowDisposal(row);
  }

  void _onAccountSelected(_OBLineRow row, Map<String, dynamic> account) {
    setState(() {
      row.accountId = account['id'] as String?;
      row.accountDisplay = FinanceAccountPicker.displayString(account);
      row.accountNature = account['account_nature'] as String? ?? '';
      final parent = account['parent'] as Map<String, dynamic>?;
      row.groupName = parent?['account_name'] as String? ?? '';
      final currencies = account['rim_currencies'];
      final currencyCode = currencies is Map<String, dynamic> ? currencies['currency_id'] as String? : null;
      if (row.partyCurrencyCtrl.text.isEmpty && currencyCode != null) {
        row.partyCurrencyCtrl.text = currencyCode;
      }
      // Bill No/Date only apply to Customer/Supplier accounts — clear any
      // stale value left over from picking a different account on this row.
      if (row.accountNature != 'Customer' && row.accountNature != 'Supplier') {
        row.invBillNoCtrl.clear();
        row.invBillDate = null;
      }
    });
  }

  Future<void> _save() async {
    if (!_isEditableFy) {
      _showSnack('Only the earliest financial year can be edited.', color: AppColors.negative);
      return;
    }
    final validLines = _lines.where((l) => l.accountId != null).toList();
    if (validLines.isEmpty) {
      _showSnack('Add at least one account line.', color: AppColors.negative);
      return;
    }
    if (_interLocationModel == 'INTER_ENTITY' && _locationGroupId == null) {
      _showSnack('Select a location group.', color: AppColors.negative);
      return;
    }
    for (final l in validLines) {
      if (l.partyCurrencyCtrl.text.trim().isEmpty) {
        _showSnack('Enter a Party Currency for "${l.accountDisplay}".', color: AppColors.negative);
        return;
      }
    }
    final validationError = _validateLines(validLines);
    if (validationError != null) {
      _showSnack(validationError, color: AppColors.negative);
      return;
    }

    setState(() { _saving = true; _actionError = null; });
    final session = ref.read(sessionProvider)!;
    try {
      final repo = ref.read(openingBalanceRepositoryProvider);
      final payload = validLines
          .map((l) => {
                'account_id':     l.accountId,
                'base_amount':    l.baseAmount,
                'local_amount':   l.localAmount,
                'party_amount':   l.partyAmount,
                'party_currency': l.partyCurrencyCtrl.text.trim(),
                'ob_type':        l.obType,
                'inv_bill_no':    l.invBillNoCtrl.text.trim().isEmpty ? null : l.invBillNoCtrl.text.trim(),
                'inv_bill_date':  l.invBillDate != null ? _fmtDate(l.invBillDate!) : null,
              })
          .toList();
      await repo.saveLines(
        clientId: session.clientId, companyId: session.companyId,
        fyId: _fyId!, locationGroupId: _locationGroupId,
        lines: payload, userId: session.userId,
      );
      if (mounted) {
        setState(() => _saving = false);
        _showSnack('Opening balances saved.', color: AppColors.positive);
      }
    } catch (e, st) {
      AppLogger.error('OpeningBalanceSave', e, st);
      if (mounted) {
        setState(() {
          _saving = false;
          _actionError = ErrorPresenter.format(e, action: 'save opening balances');
        });
      }
    }
  }

  // Enforced at Save, not at Excel upload (explicit instruction — upload
  // always succeeds; the user finds out exactly which account is wrong
  // when they try to save, not mid-upload). Returns the first problem
  // found, or null if every line is clean.
  String? _validateLines(List<_OBLineRow> validLines) {
    for (final l in validLines) {
      final allZero = l.baseAmount == 0 && l.localAmount == 0 && l.partyAmount == 0;
      final allNonZero = l.baseAmount != 0 && l.localAmount != 0 && l.partyAmount != 0;
      if (!allZero && !allNonZero) {
        return 'Account "${l.accountDisplay}": enter Base, Local, and Party amounts together, or leave all three as 0.';
      }
    }

    final byAccount = <String, List<_OBLineRow>>{};
    for (final l in validLines) {
      byAccount.putIfAbsent(l.accountId!, () => []).add(l);
    }
    for (final rows in byAccount.values) {
      if (rows.length <= 1) continue;
      final nature = rows.first.accountNature;
      if (nature != 'Customer' && nature != 'Supplier') {
        return 'Account "${rows.first.accountDisplay}" has ${rows.length} lines — only Customer/Supplier accounts can have more than one line.';
      }
      // Duplicate Bill No + Bill Date within the same account — only
      // checked when a Bill No was actually entered; two blank-bill rows
      // aren't a "duplicate reference," just missing data on both.
      final seen = <String>{};
      for (final r in rows) {
        final billNo = r.invBillNoCtrl.text.trim();
        if (billNo.isEmpty) continue;
        final key = '${billNo.toLowerCase()}|${r.invBillDate != null ? _fmtDate(r.invBillDate!) : ''}';
        if (!seen.add(key)) {
          final dateStr = r.invBillDate != null ? ' dated ${_fmtDate(r.invBillDate!)}' : '';
          return 'Account "${r.accountDisplay}" has duplicate Invoice/Bill No "$billNo"$dateStr.';
        }
      }
    }
    return null;
  }

  Future<void> _uploadExcel() async {
    if (!_isEditableFy) {
      _showSnack('Only the earliest financial year can be edited.', color: AppColors.negative);
      return;
    }
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom, allowedExtensions: ['xlsx'], withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final bytes = result.files.first.bytes;
    if (bytes == null) { _showSnack('Could not read the selected file.', color: AppColors.negative); return; }

    setState(() => _uploadingExcel = true);
    try {
      final workbook = xls.Excel.decodeBytes(bytes);
      if (workbook.tables.isEmpty) { _showSnack('The file has no sheets.', color: AppColors.negative); return; }
      final sheet = workbook.tables[workbook.tables.keys.first]!;
      if (sheet.maxRows < 2) { _showSnack('No data rows found below the header.', color: AppColors.negative); return; }

      final byCode = {
        for (final a in _postableAccounts) (a['account_code'] as String).toUpperCase(): a,
      };

      final headerCells = sheet.row(0);
      final headerNames = headerCells.map((c) => c?.value?.toString().trim().toLowerCase() ?? '').toList();
      int col(String name) => headerNames.indexOf(name);
      final idxCode     = col('account code');
      final idxBase     = col('base amount');
      final idxLocal    = col('local amount');
      final idxParty    = col('party amount');
      final idxCurrency = col('party currency');
      final idxType     = col('opening balance type');
      final idxBillNo   = col('invoice/bill no');
      final idxBillDate = col('invoice/bill date');

      if (idxCode == -1 || idxType == -1) {
        _showSnack('Missing required column(s): Account Code, Opening Balance Type.', color: AppColors.negative);
        return;
      }

      String cellStr(List<xls.Data?> row, int idx) =>
          (idx == -1 || idx >= row.length) ? '' : (row[idx]?.value?.toString().trim() ?? '');

      // Replace, not append — the template is now a round-trip export of
      // the current worksheet (see _downloadTemplate), so re-uploading the
      // edited copy should reflect exactly what's in the sheet, not pile
      // duplicate rows for the same account on top of what was already here.
      //
      // A row is treated as an untouched placeholder (silently skipped, no
      // error) ONLY when Opening Balance Type is blank — that's the one
      // signal a freshly-downloaded, never-edited row always has. Once a
      // real Dr/Cr type is present the row is a deliberate entry and is
      // uploaded as-is, INCLUDING an explicit zero balance — a user
      // correcting a wrongly-uploaded non-zero figure back to 0 needs that
      // to actually save, not be silently dropped. Duplicate-account/
      // duplicate-bill/all-3-or-none-amount checks are NOT done here —
      // per explicit instruction, upload always succeeds; those are
      // enforced at Save time instead, with a clear per-account message.
      final parsedRows = <_OBLineRow>[];
      var skippedBlank = 0;
      final errors = <String>[];
      for (var r = 1; r < sheet.maxRows; r++) {
        final row = sheet.row(r);
        final code = cellStr(row, idxCode);
        if (code.isEmpty) continue;
        final account = byCode[code.toUpperCase()];
        if (account == null) { errors.add('Row ${r + 1}: account code "$code" not found (or not a postable account).'); continue; }
        final type = cellStr(row, idxType);
        if (type.isEmpty) { skippedBlank++; continue; }
        if (type != 'Dr' && type != 'Cr') { errors.add('Row ${r + 1}: Opening Balance Type must be "Dr" or "Cr", got "$type".'); continue; }

        final baseStr  = idxBase == -1 ? '' : cellStr(row, idxBase);
        final localStr = idxLocal == -1 ? '' : cellStr(row, idxLocal);
        final partyStr = idxParty == -1 ? '' : cellStr(row, idxParty);
        final billNoStr = idxBillNo == -1 ? '' : cellStr(row, idxBillNo);

        final newRow = _OBLineRow();
        newRow.accountId = account['id'] as String?;
        newRow.accountDisplay = FinanceAccountPicker.displayString(account);
        newRow.accountNature = account['account_nature'] as String? ?? '';
        final parent = account['parent'] as Map<String, dynamic>?;
        newRow.groupName = parent?['account_name'] as String? ?? '';
        newRow.baseAmountCtrl.text = baseStr.isEmpty ? '0' : baseStr;
        newRow.localAmountCtrl.text = localStr.isEmpty ? '0' : localStr;
        newRow.partyAmountCtrl.text = partyStr.isEmpty ? '0' : partyStr;
        final currencies = account['rim_currencies'];
        final defaultCurrency = currencies is Map<String, dynamic> ? currencies['currency_id'] as String? : null;
        final sheetCurrency = idxCurrency == -1 ? '' : cellStr(row, idxCurrency);
        newRow.partyCurrencyCtrl.text = sheetCurrency.isNotEmpty ? sheetCurrency : (defaultCurrency ?? '');
        newRow.obType = type;
        if (newRow.accountNature == 'Customer' || newRow.accountNature == 'Supplier') {
          newRow.invBillNoCtrl.text = billNoStr;
          final billDateStr = idxBillDate == -1 ? '' : cellStr(row, idxBillDate);
          newRow.invBillDate = billDateStr.isEmpty ? null : DateTime.tryParse(billDateStr);
        }
        parsedRows.add(newRow);
      }

      if (!mounted) return;
      for (final l in _lines) {
        deferRowDisposal(l);
      }
      setState(() {
        _lines
          ..clear()
          ..addAll(parsedRows);
      });
      if (errors.isNotEmpty) {
        _showSnack('${parsedRows.length} row(s) loaded, ${errors.length} row(s) skipped.', color: Colors.orange);
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Rows skipped'),
            content: SizedBox(width: 420, child: SingleChildScrollView(child: Text(errors.join('\n')))),
            actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(), child: const Text('OK'))],
          ),
        );
      } else {
        _showSnack('${parsedRows.length} row(s) loaded from Excel ($skippedBlank blank row(s) ignored).', color: AppColors.positive);
      }
    } catch (e, st) {
      AppLogger.error('OpeningBalanceExcelUpload', e, st);
      if (mounted) _showSnack(ErrorPresenter.format(e, action: 'upload this Excel file'), color: AppColors.negative);
    } finally {
      if (mounted) setState(() => _uploadingExcel = false);
    }
  }

  Future<void> _downloadTemplate() async {
    final workbook = xls.Excel.createExcel();
    final sheetName = workbook.getDefaultSheet()!;
    final sheet = workbook[sheetName];
    const headers = [
      'Group Name', 'Account Code', 'Account Name', 'Base Amount', 'Local Amount', 'Party Amount',
      'Party Currency', 'Opening Balance Type', 'Invoice/Bill No', 'Invoice/Bill Date',
    ];
    sheet.appendRow(headers.map((h) => xls.TextCellValue(h)).toList());

    // Pre-filled with every posting-allowed account's CURRENT opening
    // balance for this FY+Group scope — one row per existing bill-line for
    // an account with several, one blank amount row for an account with
    // none yet — so the user edits/fills the real sheet instead of
    // starting from a blank template and re-typing every account code.
    // Group Name is display-only context (helps identify an account by its
    // parent group) — never matched against on upload, Account Code alone
    // is the match key, same as Account Name already was.
    final linesByAccount = <String, List<_OBLineRow>>{};
    for (final l in _lines) {
      if (l.accountId == null) continue;
      linesByAccount.putIfAbsent(l.accountId!, () => []).add(l);
    }
    for (final account in _postableAccounts) {
      final accountId = account['id'] as String;
      final code = account['account_code'] as String? ?? '';
      final name = account['account_name'] as String? ?? '';
      final parent = account['parent'] as Map<String, dynamic>?;
      final groupName = parent?['account_name'] as String? ?? '';
      final existing = linesByAccount[accountId];
      if (existing == null || existing.isEmpty) {
        // Party Currency is always the account's own account_currency_id —
        // default it here too, not just when a line is picked interactively
        // on-screen, so a blank row doesn't leave the user guessing.
        final currencies = account['rim_currencies'];
        final defaultCurrency = currencies is Map<String, dynamic> ? currencies['currency_id'] as String? : null;
        sheet.appendRow([
          xls.TextCellValue(groupName), xls.TextCellValue(code), xls.TextCellValue(name),
          const xls.DoubleCellValue(0), const xls.DoubleCellValue(0), const xls.DoubleCellValue(0),
          xls.TextCellValue(defaultCurrency ?? ''), xls.TextCellValue(''), xls.TextCellValue(''), xls.TextCellValue(''),
        ]);
      } else {
        for (final l in existing) {
          sheet.appendRow([
            xls.TextCellValue(groupName), xls.TextCellValue(code), xls.TextCellValue(name),
            xls.DoubleCellValue(double.tryParse(l.baseAmountCtrl.text) ?? 0),
            xls.DoubleCellValue(double.tryParse(l.localAmountCtrl.text) ?? 0),
            xls.DoubleCellValue(double.tryParse(l.partyAmountCtrl.text) ?? 0),
            xls.TextCellValue(l.partyCurrencyCtrl.text), xls.TextCellValue(l.obType),
            xls.TextCellValue(l.invBillNoCtrl.text), xls.TextCellValue(l.invBillDate != null ? _fmtDate(l.invBillDate!) : ''),
          ]);
        }
      }
    }

    final bytes = workbook.encode();
    if (bytes == null) return;
    await _saveWorkbookBytes(bytes, 'opening_balance_template.xlsx', 'Save Opening Balance template');
  }

  // FilePicker.platform.saveFile() goes through Chrome's File System Access
  // API on web, which requires a still-valid "user activation" — timing-
  // sensitive enough that it silently fails here. Same fix already proven
  // in lib/core/reporting/report_excel_export.dart: a Blob+anchor download
  // on web, FilePicker unchanged on every other platform.
  Future<void> _saveWorkbookBytes(List<int> bytes, String filename, String dialogTitle) async {
    if (kIsWeb) {
      downloadBytesOnWeb(bytes, filename);
      return;
    }
    await FilePicker.platform.saveFile(
      dialogTitle: dialogTitle,
      fileName: filename,
      bytes: Uint8List.fromList(bytes),
      type: FileType.custom, allowedExtensions: ['xlsx'],
    );
  }

  String _fmtDate(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  void _showSnack(String msg, {Color color = AppColors.positive}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  @override
  ScreenHeaderInfo buildScreenHeader() {
    final showDesktopActions = !Responsive.isMobile(context);
    return ScreenHeaderInfo(
      title: 'Opening Balance',
      helpText: 'Enter each account\'s opening balance for a financial year — one or more rows per account, '
          'optionally tied to a historical Invoice/Bill No and Date.',
      // Template/Upload/Save all require the earliest (editable) FY — a
      // later, view-only year has nothing to export-for-editing or save.
      actions: showDesktopActions
          ? [
              if (canExcelUpload && _editable)
                SakalHeaderActionButton(
                  label: 'Template', icon: Icons.download_outlined, kind: SakalActionKind.neutral,
                  onPressed: _downloadTemplate,
                ),
              if (canExcelUpload && _editable)
                SakalHeaderActionButton(
                  label: 'Upload Excel', icon: Icons.upload_file_outlined, kind: SakalActionKind.neutral,
                  loading: _uploadingExcel, onPressed: _uploadingExcel ? null : _uploadExcel,
                ),
              if (_editable)
                SakalHeaderActionButton(
                  label: 'Save', icon: Icons.save_outlined, kind: SakalActionKind.save,
                  loading: _saving, onPressed: _saving ? null : _save,
                ),
            ]
          : const [],
    );
  }

  @override
  Widget build(BuildContext context) {
    refreshScreenHeader();
    final isMobile = Responsive.isMobile(context);
    final isCompact = ref.watch(isCompactDensityProvider);
    const bare = SakalFieldCard.bareDecoration;
    final style = SakalFieldCard.valueTextStyle(isCompact);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isMobile && _editable)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              if (canExcelUpload) OutlinedButton.icon(onPressed: _downloadTemplate, icon: const Icon(Icons.download_outlined, size: 16), label: const Text('Template')),
              if (canExcelUpload) OutlinedButton.icon(onPressed: _uploadingExcel ? null : _uploadExcel, icon: const Icon(Icons.upload_file_outlined, size: 16), label: const Text('Upload Excel')),
              FilledButton.icon(onPressed: _saving ? null : _save, icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save_outlined), label: const Text('Save')),
            ]),
          ),
        if (!_isEditableFy && !_loading)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: AppColors.secondary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
              child: const Row(children: [
                Icon(Icons.info_outline, size: 16, color: AppColors.secondary),
                SizedBox(width: 8),
                Expanded(child: Text(
                  'This is not the earliest financial year — shown read-only. Only the earliest year can be edited.',
                  style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                )),
              ]),
            ),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AppColors.negative))),
                    if (_actionError != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_actionError!, style: const TextStyle(color: AppColors.negative))),
                    _buildHeaderCard(isMobile, style, bare),
                    const SizedBox(height: 20),
                    _buildLinesSection(isMobile, style, bare),
                  ]),
                ),
        ),
      ],
    );
  }

  Widget _buildHeaderCard(bool isMobile, TextStyle style, InputDecoration bare) {
    final fyField = SakalFieldCard(
      label: 'Financial Year', required: true, editable: true,
      child: DropdownButtonFormField<String>(
        key: ValueKey(_fyId),
        initialValue: _fyId,
        isExpanded: true, isDense: true, itemHeight: null,
        decoration: bare, style: style,
        items: _financialYears.map((f) => DropdownMenuItem(value: f['id'] as String, child: Text(f['fy_name'] as String, overflow: TextOverflow.ellipsis, style: style))).toList(),
        onChanged: (v) {
          if (v == null) return;
          setState(() => _fyId = v);
          _loadLines();
        },
      ),
    );

    final groupSelected = _accessibleGroups.any((g) => g['id'] == _locationGroupId) ? _locationGroupId : null;
    final groupField = SakalFieldCard(
      label: 'Location Group', required: true, editable: true,
      child: DropdownButtonFormField<String>(
        key: ValueKey(_locationGroupId),
        initialValue: groupSelected,
        isExpanded: true, isDense: true, itemHeight: null,
        decoration: bare, style: style,
        items: _accessibleGroups.map((g) => DropdownMenuItem(value: g['id'] as String, child: Text(g['group_name'] as String, overflow: TextOverflow.ellipsis, style: style))).toList(),
        onChanged: (v) {
          setState(() => _locationGroupId = v);
          _loadLines();
        },
      ),
    );

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SakalFieldRow(isMobile: isMobile, children: [
          fyField,
          if (_interLocationModel == 'INTER_ENTITY') groupField,
        ]),
      ),
    );
  }

  Widget _buildLinesSection(bool isMobile, TextStyle style, InputDecoration bare) {
    final visible = _visibleLines;
    // Computed once, then embedded either as a plain vertical spread
    // (mobile) or wrapped in SakalScrollableTable (desktop) — see
    // CLAUDE.md's "Line-items grid" mandatory pattern. A bare Wrap here
    // (the original implementation) let fields drop to a second line even
    // on wide desktop viewports — this is the fix.
    final lineWidgets = visible.map((row) => _buildLineCard(row, style, bare, isMobile)).toList();
    // Total Debit/Credit across ALL lines (not just the search-filtered
    // subset), Base and Local only — Party amounts are in each account's
    // own currency, so summing them across accounts would mix currencies
    // meaninglessly. Lets the user cross-check against their own Excel
    // sheet's own totals.
    var totalBaseDr = 0.0, totalBaseCr = 0.0, totalLocalDr = 0.0, totalLocalCr = 0.0;
    for (final l in _lines) {
      if (l.accountId == null) continue;
      if (l.obType == 'Dr') {
        totalBaseDr += l.baseAmount;
        totalLocalDr += l.localAmount;
      } else {
        totalBaseCr += l.baseAmount;
        totalLocalCr += l.localAmount;
      }
    }
    String fmt(double v) => v.toStringAsFixed(2);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Expanded(child: Text('Opening Balance Lines', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
        if (_editable) IconButton(onPressed: _addLine, icon: const Icon(Icons.add_circle_outline), tooltip: 'Add Line'),
      ]),
      if (_lines.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Wrap(spacing: 16, runSpacing: 4, children: [
            Text('Base — Dr ${fmt(totalBaseDr)} / Cr ${fmt(totalBaseCr)}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
            Text('Local — Dr ${fmt(totalLocalDr)} / Cr ${fmt(totalLocalCr)}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
          ]),
        ),
      SakalFieldCard(
        label: 'Search', editable: true,
        child: TextFormField(
          controller: _searchCtrl,
          decoration: bare.copyWith(
            hintText: 'Search by account code/name or Invoice/Bill No…',
            prefixIcon: const Icon(Icons.search, size: 18, color: AppColors.textSecondary),
          ),
          style: style,
          onChanged: (v) => setState(() => _searchQuery = v.trim()),
        ),
      ),
      const SizedBox(height: 12),
      if (_lines.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: Text('No lines yet — add one, or upload an Excel sheet.', style: TextStyle(color: AppColors.textSecondary))),
        )
      else if (visible.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: Text('No lines match this search.', style: TextStyle(color: AppColors.textSecondary))),
        )
      else if (isMobile)
        ...lineWidgets
      else
        SakalScrollableTable(header: _buildLinesHeader(), rows: lineWidgets),
    ]);
  }

  // Same left-to-right column order/widths as _buildLineCard's own desktop
  // Row below, so the two stay pixel-aligned.
  Widget _buildLinesHeader() {
    return SakalTableHeaderBar(cells: [
      SizedBox(width: 180, child: SakalTableHeaderBar.label('Group')),
      const SizedBox(width: 8),
      SizedBox(width: 320, child: SakalTableHeaderBar.label('Account')),
      const SizedBox(width: 8),
      SizedBox(width: 90, child: SakalTableHeaderBar.label('Type')),
      const SizedBox(width: 8),
      SizedBox(width: 110, child: SakalTableHeaderBar.label('Base Amount')),
      const SizedBox(width: 8),
      SizedBox(width: 110, child: SakalTableHeaderBar.label('Local Amount')),
      const SizedBox(width: 8),
      SizedBox(width: 110, child: SakalTableHeaderBar.label('Party Amount')),
      const SizedBox(width: 8),
      SizedBox(width: 90, child: SakalTableHeaderBar.label('Party Ccy')),
      const SizedBox(width: 8),
      SizedBox(width: 140, child: SakalTableHeaderBar.label('Bill No')),
      const SizedBox(width: 8),
      SizedBox(width: 130, child: SakalTableHeaderBar.label('Bill Date')),
      const SizedBox(width: 40), // reserves the delete-icon column's width
    ]);
  }

  Widget _buildLineCard(_OBLineRow row, TextStyle style, InputDecoration bare, bool isMobile) {
    // Invoice/Bill No + Date only make sense for Customer/Supplier accounts
    // — a Cash/Bank/General account's opening balance has no bill to
    // reference. Column stays in the layout either way (alignment), the
    // input itself is disabled when it doesn't apply.
    final showBill = row.accountNature == 'Customer' || row.accountNature == 'Supplier';
    final groupField = SakalFieldCard.readOnly(label: 'Group', value: row.groupName.isEmpty ? '—' : row.groupName);
    final accountField = SakalFieldCard(
      label: 'Account', required: true, editable: _editable,
      child: FinanceAccountPicker(
        accounts: _postableAccounts,
        initialValue: row.accountDisplay.isEmpty ? null : row.accountDisplay,
        enabled: _editable,
        focusNode: row.accountFocusNode,
        decoration: bare,
        onSelected: (a) => _onAccountSelected(row, a),
      ),
    );
    final typeField = SakalFieldCard(
      label: 'Type', editable: _editable,
      child: DropdownButtonFormField<String>(
        initialValue: row.obType,
        isExpanded: true, isDense: true, itemHeight: null,
        decoration: bare, style: style,
        items: const [DropdownMenuItem(value: 'Dr', child: Text('Dr')), DropdownMenuItem(value: 'Cr', child: Text('Cr'))],
        onChanged: _editable ? (v) => setState(() => row.obType = v ?? 'Dr') : null,
      ),
    );
    final baseField = _amountField('Base Amount', row.baseAmountCtrl, bare, _editable);
    final localField = _amountField('Local Amount', row.localAmountCtrl, bare, _editable);
    final partyField = _amountField('Party Amount', row.partyAmountCtrl, bare, _editable);
    final currencyField = SakalFieldCard(
      label: 'Party Ccy', required: true, editable: _editable,
      child: TextFormField(controller: row.partyCurrencyCtrl, enabled: _editable, decoration: bare, style: style),
    );
    final billNoField = SakalFieldCard(
      label: 'Bill No', editable: _editable && showBill,
      child: TextFormField(controller: row.invBillNoCtrl, enabled: _editable && showBill, decoration: bare, style: style),
    );
    final billDateField = SakalFieldCard(
      label: 'Bill Date', editable: _editable && showBill,
      child: InkWell(
        onTap: (_editable && showBill)
            ? () async {
                final d = await showDatePicker(context: context, initialDate: row.invBillDate ?? DateTime.now(), firstDate: DateTime(2000), lastDate: DateTime(2100));
                if (d != null) setState(() => row.invBillDate = d);
              }
            : null,
        child: Text(row.invBillDate != null ? _fmtDate(row.invBillDate!) : '—',
            style: style.copyWith(color: showBill ? style.color : AppColors.textDisabled)),
      ),
    );

    if (isMobile) {
      // 2-column grid instead of a loose Wrap — same convention as GRN's
      // own mobile line-card fix (see CLAUDE.md's "Line-items grid").
      final secondaryFields = <Widget>[typeField, baseField, localField, partyField, currencyField, billNoField, billDateField];
      final pairedRows = <Widget>[];
      for (var i = 0; i < secondaryFields.length; i += 2) {
        pairedRows.add(SakalFieldRow(isMobile: true, children: secondaryFields.sublist(i, (i + 2).clamp(0, secondaryFields.length))));
        if (i + 2 < secondaryFields.length) pairedRows.add(const SizedBox(height: 8));
      }
      return SakalLineItemCard(
        title: row.accountDisplay.isEmpty ? 'New Line' : row.accountDisplay,
        onDelete: _editable ? () => _removeLine(row) : null,
        fields: const [],
        body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          groupField,
          const SizedBox(height: 8),
          accountField,
          const SizedBox(height: 8),
          ...pairedRows,
        ]),
      );
    }

    // Desktop — a continuous row under _buildLinesHeader's dark bar, same
    // column widths so the two stay pixel-aligned.
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 180, child: groupField),
        const SizedBox(width: 8),
        SizedBox(width: 320, child: accountField),
        const SizedBox(width: 8),
        SizedBox(width: 90, child: typeField),
        const SizedBox(width: 8),
        SizedBox(width: 110, child: baseField),
        const SizedBox(width: 8),
        SizedBox(width: 110, child: localField),
        const SizedBox(width: 8),
        SizedBox(width: 110, child: partyField),
        const SizedBox(width: 8),
        SizedBox(width: 90, child: currencyField),
        const SizedBox(width: 8),
        SizedBox(width: 140, child: billNoField),
        const SizedBox(width: 8),
        SizedBox(width: 130, child: billDateField),
        SizedBox(
          width: 40,
          child: _editable ? IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => _removeLine(row), tooltip: 'Remove line') : null,
        ),
      ]),
    );
  }

  Widget _amountField(String label, TextEditingController ctrl, InputDecoration bare, bool editable) => SakalFieldCard(
        label: label, editable: editable, numeric: true,
        child: TextFormField(
          controller: ctrl,
          enabled: editable,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,4}'))],
          decoration: bare,
          textAlign: TextAlign.right,
        ),
      );
}
