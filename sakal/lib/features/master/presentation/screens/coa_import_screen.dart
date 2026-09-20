import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:excel/excel.dart' as xls;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/layout/screen_header.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/reporting/web_download.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../core/utils/deferred_row_disposal.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/sakal_autocomplete.dart';
import '../../../../core/widgets/sakal_header_action_button.dart';
import '../../../../core/widgets/sakal_line_item_card.dart';

/// Chart of Accounts Import — a reconciliation wizard (route
/// /master/coa-import, feature MST-COAI, Finance Masters group) that
/// replaces the old plain "insert new leaf" bulk upload that used to live
/// on the Chart of Accounts screen. Full design:
/// sakal/docs/screens/plan_chart_of_accounts_import.md.
///
/// SAKAL_COA ∪ (Client_COA − SAKAL_COA): every row is either MAPPED onto
/// an existing SAKAL account (only `external_code` is written — an
/// existing account's own name/details are never touched by a client
/// import) or CREATED as a brand-new leaf under an EXISTING, protected
/// group. This screen never creates a new top-level group — SAKAL's own
/// group hierarchy is load-bearing for the Hierarchical P&L/Balance
/// Sheet/Cash Flow reports (see CLAUDE.md).
class CoaImportScreen extends ConsumerStatefulWidget {
  const CoaImportScreen({super.key});

  @override
  ConsumerState<CoaImportScreen> createState() => _CoaImportScreenState();
}

const _natures = ['General', 'Customer', 'Supplier', 'Cash', 'Bank', 'Employee', 'Tax'];
const _partyTypes = ['Individual', 'Company', 'Partnership', 'Government'];
const _actionLabels = {'MAP': 'Map to Existing', 'CREATE': 'Create New', 'SKIP': 'Skip'};

const _gridFontSize = 11.0;
const _gridRowVPad = 5.0;
final _gridCellDecoration = BoxDecoration(border: Border.all(color: AppColors.border, width: 0.6));

class _CoaRow implements DisposableRow {
  final clientCodeCtrl = TextEditingController();
  final clientNameCtrl = TextEditingController();
  String nature = 'General';
  final clientGroupCtrl = TextEditingController();
  final currencyCtrl = TextEditingController();
  final newCodeCtrl = TextEditingController();

  // Party details — only meaningful for a CREATE row of nature
  // Customer/Supplier, edited via the compact dialog below.
  String? partyType;
  final contactCtrl = TextEditingController();
  final phoneCtrl = TextEditingController();
  final emailCtrl = TextEditingController();
  final addr1Ctrl = TextEditingController();
  final addr2Ctrl = TextEditingController();
  final taxIdCtrl = TextEditingController();
  final creditDaysCtrl = TextEditingController(text: '30');
  final creditLimitCtrl = TextEditingController();

  // Reconciliation state
  Map<String, dynamic>? suggestedAccount; // {id, account_code, account_name}
  double? suggestedScore;
  String action = 'CREATE'; // 'MAP' | 'CREATE' | 'SKIP'
  Map<String, dynamic>? parentGroup; // {id, account_code, account_name, accounting_std}

  // True when Parent Group (and usually New Code) came pre-resolved from
  // the upload's own optional "Parent Account Code"/"New Account Code"
  // columns — i.e. the user already knows exactly where this account
  // belongs (a hand-mapped onboarding file) and doesn't need the fuzzy
  // suggestion engine to guess. A preset row's action is never silently
  // flipped to MAP by a later suggestion match (see _fetchSuggestions) —
  // the suggestion still shows for visibility, but doesn't override intent.
  bool hasPresetParent = false;

  bool get isParty => nature == 'Customer' || nature == 'Supplier';

  @override
  void dispose() {
    for (final c in [
      clientCodeCtrl, clientNameCtrl, clientGroupCtrl, currencyCtrl, newCodeCtrl,
      contactCtrl, phoneCtrl, emailCtrl, addr1Ctrl, addr2Ctrl, taxIdCtrl,
      creditDaysCtrl, creditLimitCtrl,
    ]) {
      c.dispose();
    }
  }
}

class _CoaImportScreenState extends ConsumerState<CoaImportScreen>
    with
        ScreenPermissionMixin<CoaImportScreen>,
        ScreenHeaderMixin<CoaImportScreen>,
        DeferredRowDisposal<CoaImportScreen> {
  @override
  String get screenName => RouteNames.coaImport;

  List<_CoaRow> _lines = [];
  List<Map<String, dynamic>> _postingAccounts = [];
  List<Map<String, dynamic>> _groupAccounts = [];
  List<Map<String, dynamic>> _currencies = [];
  bool _loadingMasters = true;
  bool _uploadingExcel = false;
  bool _matching = false;
  bool _saving = false;
  String? _progressText;

  // "Parent Account Code" / "New Account Code" are both OPTIONAL — for the
  // common case (you don't yet know what overlaps with SAKAL's own
  // accounts), leave them blank and use the Suggested Match / Parent Group
  // pickers on screen instead. When you already know exactly where an
  // account belongs (e.g. a hand-mapped onboarding file), fill these two
  // in and that row arrives pre-set to Create New with its parent already
  // chosen — no picking required, just review and Import.
  static const _uploadHeaders = [
    'Client Account Code', 'Client Account Name', 'Nature',
    'Parent Account Code', 'New Account Code', 'Client Group/Category',
    'Currency', 'Party Type', 'Contact Person', 'Phone', 'Email',
    'Address Line 1', 'Address Line 2', 'Tax ID', 'Credit Days', 'Credit Limit',
  ];

  String _norm(String s) => s.trim().toUpperCase();

  @override
  void initState() {
    super.initState();
    _hHeaderController.addListener(() => _syncHScroll(_hHeaderController, _hBodyController));
    _hBodyController.addListener(() => _syncHScroll(_hBodyController, _hHeaderController));
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMasters());
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    disposeDeferredRows();
    _vController.dispose();
    _hHeaderController.dispose();
    _hBodyController.dispose();
    super.dispose();
  }

  Future<void> _loadMasters() async {
    final session = ref.read(sessionProvider)!;
    setState(() => _loadingMasters = true);
    try {
      final accountsRes = await DioClient.instance.get('/rim_accounts', queryParameters: {
        'client_id':  'eq.${session.clientId}',
        'company_id': 'eq.${session.companyId}',
        'is_deleted': 'eq.false',
        'select':     'id,account_code,account_name,account_nature,posting_allowed,accounting_std',
        'order':      'account_code.asc',
        'limit':      '5000',
      });
      final accounts = List<Map<String, dynamic>>.from(accountsRes.data as List);
      final currencies = await ref.read(currenciesProvider.future);
      if (!mounted) return;
      setState(() {
        _postingAccounts = accounts.where((a) => a['posting_allowed'] == true).toList();
        _groupAccounts   = accounts.where((a) => a['posting_allowed'] == false).toList();
        _currencies      = currencies;
        _loadingMasters  = false;
      });
    } on DioException {
      if (mounted) setState(() => _loadingMasters = false);
    }
  }

  // ── Template / Upload ──────────────────────────────────────────────────

  Future<void> _downloadTemplate() async {
    final workbook = xls.Excel.createExcel();
    final sheetName = workbook.getDefaultSheet()!;
    final sheet = workbook[sheetName];
    sheet.appendRow(_uploadHeaders.map((h) => xls.TextCellValue(h)).toList());
    final bytes = workbook.encode();
    if (bytes == null) return;
    await _saveWorkbookBytes(bytes, 'coa_import_template.xlsx', 'Save Chart of Accounts Import template');
  }

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

  Future<void> _uploadExcel() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom, allowedExtensions: ['xlsx'], withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final bytes = result.files.first.bytes;
    if (bytes == null) { _showSnack('Could not read the selected file.', AppColors.negative); return; }

    setState(() { _uploadingExcel = true; _progressText = 'Reading file…'; });
    try {
      final workbook = xls.Excel.decodeBytes(bytes);
      if (workbook.tables.isEmpty) { _showSnack('The file has no sheets.', AppColors.negative); return; }
      final sheet = workbook.tables[workbook.tables.keys.first]!;
      if (sheet.maxRows < 2) { _showSnack('No data rows found below the header.', AppColors.negative); return; }

      final headerCells = sheet.row(0);
      final headerNames = headerCells.map((c) => c?.value?.toString().trim().toLowerCase() ?? '').toList();
      int col(String name) => headerNames.indexOf(name);
      final idxCode     = col('client account code');
      final idxName     = col('client account name');
      final idxNature   = col('nature');
      final idxParentCode = col('parent account code');
      final idxNewCode  = col('new account code');
      final idxGroup    = col('client group/category');
      final idxCurrency = col('currency');
      final idxPartyType = col('party type');
      final idxContact  = col('contact person');
      final idxPhone    = col('phone');
      final idxEmail    = col('email');
      final idxAddr1    = col('address line 1');
      final idxAddr2    = col('address line 2');
      final idxTaxId    = col('tax id');
      final idxCreditDays = col('credit days');
      final idxCreditLimit = col('credit limit');

      if (idxName == -1) {
        _showSnack('Missing required column: Client Account Name.', AppColors.negative);
        return;
      }

      String cellStr(List<xls.Data?> row, int idx) =>
          (idx == -1 || idx >= row.length) ? '' : (row[idx]?.value?.toString().trim() ?? '');

      final parsed = <_CoaRow>[];
      var presetCount = 0;
      var unresolvedParentCount = 0;
      for (var r = 1; r < sheet.maxRows; r++) {
        final row = sheet.row(r);
        final name = cellStr(row, idxName);
        if (name.isEmpty) continue;
        final line = _CoaRow();
        line.clientCodeCtrl.text = idxCode == -1 ? '' : cellStr(row, idxCode);
        line.clientNameCtrl.text = name;
        final rawNature = idxNature == -1 ? '' : cellStr(row, idxNature);
        line.nature = _natures.contains(rawNature) ? rawNature : 'General';
        line.clientGroupCtrl.text = idxGroup == -1 ? '' : cellStr(row, idxGroup);
        line.currencyCtrl.text = idxCurrency == -1 ? '' : cellStr(row, idxCurrency);
        if (line.isParty) {
          final rawPartyType = idxPartyType == -1 ? '' : cellStr(row, idxPartyType);
          line.partyType = _partyTypes.contains(rawPartyType) ? rawPartyType : null;
          line.contactCtrl.text = idxContact == -1 ? '' : cellStr(row, idxContact);
          line.phoneCtrl.text = idxPhone == -1 ? '' : cellStr(row, idxPhone);
          line.emailCtrl.text = idxEmail == -1 ? '' : cellStr(row, idxEmail);
          line.addr1Ctrl.text = idxAddr1 == -1 ? '' : cellStr(row, idxAddr1);
          line.addr2Ctrl.text = idxAddr2 == -1 ? '' : cellStr(row, idxAddr2);
          line.taxIdCtrl.text = idxTaxId == -1 ? '' : cellStr(row, idxTaxId);
          final days = idxCreditDays == -1 ? '' : cellStr(row, idxCreditDays);
          line.creditDaysCtrl.text = days.isEmpty ? '30' : days;
          line.creditLimitCtrl.text = idxCreditLimit == -1 ? '' : cellStr(row, idxCreditLimit);
        }

        // Optional pre-mapping — a hand-mapped onboarding file already
        // knows exactly where each account belongs, so skip the fuzzy
        // suggestion engine for that row entirely: resolve Parent Group
        // right now by code, pre-fill New Account Code if given, and lock
        // the action to Create New (never silently flipped to Map later —
        // see hasPresetParent's own doc comment on _CoaRow).
        final parentCodeStr = idxParentCode == -1 ? '' : cellStr(row, idxParentCode);
        if (parentCodeStr.isNotEmpty) {
          final normParentCode = _norm(parentCodeStr);
          Map<String, dynamic>? match;
          for (final g in _groupAccounts) {
            if (_norm(g['account_code'] as String? ?? '') == normParentCode) { match = g; break; }
          }
          if (match != null) {
            line.parentGroup = match;
            line.hasPresetParent = true;
            line.action = 'CREATE';
            line.newCodeCtrl.text = idxNewCode == -1 ? '' : cellStr(row, idxNewCode);
            presetCount++;
          } else {
            unresolvedParentCount++;
          }
        }
        parsed.add(line);
      }

      if (!mounted) return;
      for (final l in _lines) {
        deferRowDisposal(l);
      }
      setState(() => _lines = parsed);

      // Any preset row missing an explicit New Account Code still needs
      // one before Import — fetch it now (same fn_next_account_code every
      // manual parent-pick already uses) so the grid opens fully ready to
      // review rather than showing a blank code the user has to notice
      // and fix themselves.
      final needsCodeLookup = parsed.where((r) => r.hasPresetParent && r.newCodeCtrl.text.trim().isEmpty).toList();
      if (needsCodeLookup.isNotEmpty) {
        setState(() => _progressText = 'Generating account codes…');
        final session = ref.read(sessionProvider)!;
        for (final r in needsCodeLookup) {
          try {
            final codeRes = await DioClient.instance.post('/rpc/fn_next_account_code', data: {
              'p_client_id': session.clientId, 'p_company_id': session.companyId, 'p_parent_id': r.parentGroup!['id'],
            });
            r.newCodeCtrl.text = codeRes.data as String? ?? '';
          } on DioException { /* leave blank — user can type it in */ }
        }
        if (mounted) setState(() {});
      }

      final summary = StringBuffer('${parsed.length} row(s) loaded.');
      if (presetCount > 0) summary.write(' $presetCount pre-mapped to their parent group — ready to review.');
      if (unresolvedParentCount > 0) {
        summary.write(' $unresolvedParentCount row(s) had a Parent Account Code that wasn\'t found — pick Parent Group manually for those.');
      }
      _showSnack(summary.toString(), unresolvedParentCount > 0 ? Colors.orange : AppColors.positive);
      await _fetchSuggestions();
    } catch (e, st) {
      AppLogger.error('CoaImportExcelUpload', e, st);
      if (mounted) _showSnack(ErrorPresenter.format(e, action: 'upload this Excel file'), AppColors.negative);
    } finally {
      if (mounted) setState(() { _uploadingExcel = false; _progressText = null; });
    }
  }

  // ── Reconcile — one batched suggestion call for the whole file ─────────

  Future<void> _fetchSuggestions() async {
    if (_lines.isEmpty) return;
    final session = ref.read(sessionProvider)!;
    setState(() => _matching = true);
    try {
      final payload = [
        for (var i = 0; i < _lines.length; i++)
          {
            'row_index':   i,
            'client_name': _lines[i].clientNameCtrl.text,
            'nature':      _lines[i].nature,
          },
      ];
      final res = await DioClient.instance.post('/rpc/fn_suggest_coa_import_matches', data: {
        'p_client_id':  session.clientId,
        'p_company_id': session.companyId,
        'p_rows':       payload,
      });
      final suggestions = List<Map<String, dynamic>>.from(res.data as List);
      if (!mounted) return;
      setState(() {
        for (final s in suggestions) {
          final idx = s['row_index'] as int?;
          final accountId = s['account_id'] as String?;
          if (idx == null || idx >= _lines.length || accountId == null) continue;
          final row = _lines[idx];
          row.suggestedAccount = {
            'id': accountId, 'account_code': s['account_code'], 'account_name': s['account_name'],
          };
          row.suggestedScore = (s['score'] as num?)?.toDouble();
          // A preset row (Parent Account Code already resolved from the
          // upload) already had its intent decided — the suggestion still
          // shows for visibility (in case it flags a genuine accidental
          // duplicate worth a manual look), but never silently overrides
          // Create New back to Map.
          if (!row.hasPresetParent) row.action = 'MAP';
        }
      });
    } on DioException catch (e, st) {
      AppLogger.error('CoaImportSuggestMatches', e, st);
      if (mounted) _showSnack(ErrorPresenter.format(e, action: 'find suggested matches'), AppColors.negative);
    } finally {
      if (mounted) setState(() => _matching = false);
    }
  }

  void _addLine() => setState(() => _lines.add(_CoaRow()));

  void _removeLine(_CoaRow row) {
    if (_busy) return;
    setState(() => _lines.remove(row));
    deferRowDisposal(row);
  }

  Future<void> _onParentSelected(_CoaRow row, Map<String, dynamic> parent) async {
    setState(() => row.parentGroup = parent);
    final session = ref.read(sessionProvider)!;
    try {
      final res = await DioClient.instance.post('/rpc/fn_next_account_code', data: {
        'p_client_id':  session.clientId,
        'p_company_id': session.companyId,
        'p_parent_id':  parent['id'],
      });
      if (mounted) setState(() => row.newCodeCtrl.text = res.data as String? ?? '');
    } on DioException { /* leave blank — user can type manually */ }
  }

  bool get _busy => _saving || _uploadingExcel || _matching;

  // ── Commit ───────────────────────────────────────────────────────────────

  Future<void> _commit() async {
    final mapRows = _lines.where((r) => r.action == 'MAP').toList();
    final createRows = _lines.where((r) => r.action == 'CREATE' && r.clientNameCtrl.text.trim().isNotEmpty).toList();
    final skipCount = _lines.length - mapRows.length - createRows.length;

    if (mapRows.isEmpty && createRows.isEmpty) {
      _showSnack('Nothing to import — every row is Skip or blank.', AppColors.negative);
      return;
    }
    for (final r in mapRows) {
      if (r.suggestedAccount == null) {
        _showSnack('"${r.clientNameCtrl.text}": choose a Suggested Match account, or change Action to Create/Skip.', AppColors.negative);
        return;
      }
    }
    for (final r in createRows) {
      if (r.parentGroup == null) {
        _showSnack('"${r.clientNameCtrl.text}": choose a Parent Group for this new account.', AppColors.negative);
        return;
      }
      if (r.newCodeCtrl.text.trim().isEmpty) {
        _showSnack('"${r.clientNameCtrl.text}": New Account Code is required.', AppColors.negative);
        return;
      }
    }

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Confirm Import'),
        content: Text(
          '${mapRows.length} account(s) will be mapped to existing SAKAL accounts.\n'
          '${createRows.length} new account(s) will be created.\n'
          '$skipCount row(s) will be skipped.\n\nContinue?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Import')),
        ],
      ),
    );
    if (confirmed != true) return;

    final session = ref.read(sessionProvider)!;
    setState(() { _saving = true; _progressText = 'Importing…'; });

    final baseCurrencyCode = await ref.read(baseCurrencyProvider.future);
    Map<String, dynamic>? findCurrency(String code) {
      if (code.isEmpty) return null;
      for (final c in _currencies) {
        if (_norm(c['currency_id'] as String? ?? '') == _norm(code)) return c;
      }
      return null;
    }
    final baseCurrency = findCurrency(baseCurrencyCode);

    try {
      final mapPayload = [
        for (final r in mapRows)
          {'account_id': r.suggestedAccount!['id'], 'external_code': r.clientCodeCtrl.text.trim().nullIfEmptyC},
      ];

      final createPayload = <Map<String, dynamic>>[];
      for (final r in createRows) {
        final currency = findCurrency(r.currencyCtrl.text.trim()) ?? baseCurrency;
        if (currency == null) {
          _showSnack('"${r.clientNameCtrl.text}": no Currency could be resolved (and no base currency is configured).', AppColors.negative);
          setState(() { _saving = false; _progressText = null; });
          return;
        }
        createPayload.add({
          'parent_id':           r.parentGroup!['id'],
          'account_code':        r.newCodeCtrl.text.trim(),
          'account_name':        r.clientNameCtrl.text.trim(),
          'account_nature':      r.nature,
          'account_currency_id': currency['id'],
          'external_code':       r.clientCodeCtrl.text.trim().nullIfEmptyC,
          if (r.isParty) ...{
            'party_type':     r.partyType,
            'contact_person': r.contactCtrl.text.trim().nullIfEmptyC,
            'phone':          r.phoneCtrl.text.trim().nullIfEmptyC,
            'email':          r.emailCtrl.text.trim().nullIfEmptyC,
            'address_line1':  r.addr1Ctrl.text.trim().nullIfEmptyC,
            'address_line2':  r.addr2Ctrl.text.trim().nullIfEmptyC,
            'tax_id':         r.taxIdCtrl.text.trim().nullIfEmptyC,
            'credit_days':    int.tryParse(r.creditDaysCtrl.text.trim()) ?? 30,
            'credit_limit':   r.creditLimitCtrl.text.trim().isEmpty ? null : double.tryParse(r.creditLimitCtrl.text.trim()),
          },
        });
      }

      final res = await DioClient.instance.post('/rpc/fn_apply_coa_import', data: {
        'p_client_id':   session.clientId,
        'p_company_id':  session.companyId,
        'p_map_rows':    mapPayload,
        'p_create_rows': createPayload,
        'p_user_id':     session.userId,
      });

      ref.invalidate(accountsProvider);

      final result = res.data is Map ? res.data as Map<String, dynamic> : <String, dynamic>{};
      if (!mounted) return;
      for (final l in _lines) {
        deferRowDisposal(l);
      }
      setState(() { _lines = []; _saving = false; _progressText = null; });
      _showSnack(
        '${result['mapped'] ?? mapRows.length} account(s) mapped, ${result['created'] ?? createRows.length} account(s) created.',
        AppColors.positive,
      );
    } catch (e, st) {
      AppLogger.error('CoaImportCommit', e, st);
      if (mounted) _showSnack(ErrorPresenter.format(e, action: 'import this Chart of Accounts file'), AppColors.negative);
    } finally {
      if (mounted) setState(() { _saving = false; _progressText = null; });
    }
  }

  Widget _legendDot(Color color, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 9, height: 9, decoration: BoxDecoration(color: color.withValues(alpha: 0.7), shape: BoxShape.circle)),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
      ]);

  void _showSnack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  // ── Party details dialog ────────────────────────────────────────────────

  Future<void> _openPartyDetails(_CoaRow row) async {
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Party Details — ${row.clientNameCtrl.text}'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                DropdownButtonFormField<String>(
                  initialValue: row.partyType,
                  isExpanded: true, isDense: true, itemHeight: null,
                  decoration: const InputDecoration(labelText: 'Party Type', isDense: true),
                  items: _partyTypes.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                  onChanged: (v) => setDialogState(() => row.partyType = v),
                ),
                const SizedBox(height: 8),
                TextFormField(controller: row.contactCtrl, decoration: const InputDecoration(labelText: 'Contact Person', isDense: true)),
                const SizedBox(height: 8),
                TextFormField(controller: row.phoneCtrl, decoration: const InputDecoration(labelText: 'Phone', isDense: true)),
                const SizedBox(height: 8),
                TextFormField(controller: row.emailCtrl, decoration: const InputDecoration(labelText: 'Email', isDense: true)),
                const SizedBox(height: 8),
                TextFormField(controller: row.addr1Ctrl, decoration: const InputDecoration(labelText: 'Address Line 1', isDense: true)),
                const SizedBox(height: 8),
                TextFormField(controller: row.addr2Ctrl, decoration: const InputDecoration(labelText: 'Address Line 2', isDense: true)),
                const SizedBox(height: 8),
                TextFormField(controller: row.taxIdCtrl, decoration: const InputDecoration(labelText: 'Tax ID', isDense: true)),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: TextFormField(controller: row.creditDaysCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Credit Days', isDense: true))),
                  const SizedBox(width: 8),
                  Expanded(child: TextFormField(controller: row.creditLimitCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Credit Limit', isDense: true))),
                ]),
              ]),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(), child: const Text('Done'))],
        ),
      ),
    );
  }

  // ── UI ───────────────────────────────────────────────────────────────────

  @override
  ScreenHeaderInfo buildScreenHeader() {
    final showDesktopActions = !Responsive.isMobile(context);
    return ScreenHeaderInfo(
      title: 'Chart of Accounts Import',
      helpText: 'Upload your own Chart of Accounts and reconcile it against SAKAL\'s existing '
          'accounts — a row either maps onto an existing account or becomes a new leaf under an '
          'existing group. SAKAL never replaces or restructures its own group hierarchy. '
          'Don\'t know what already exists in SAKAL? Leave Parent Account Code/New Account Code '
          'blank in the template and use the on-screen pickers instead — every row gets a '
          'suggested match automatically. Already know exactly where an account belongs (a '
          'hand-mapped file)? Fill those two columns in and that row arrives ready to Import, '
          'no picking needed.',
      actions: showDesktopActions
          ? [
              if (canExcelUpload)
                SakalHeaderActionButton(
                  label: 'Template', icon: Icons.download_outlined, kind: SakalActionKind.neutral,
                  onPressed: _busy ? null : _downloadTemplate,
                ),
              if (canExcelUpload)
                SakalHeaderActionButton(
                  label: 'Upload Excel', icon: Icons.upload_file_outlined, kind: SakalActionKind.neutral,
                  loading: _uploadingExcel, onPressed: _busy ? null : _uploadExcel,
                ),
              SakalHeaderActionButton(
                label: 'Import', icon: Icons.check_circle_outline, kind: SakalActionKind.save,
                loading: _saving, onPressed: (_busy || _lines.isEmpty) ? null : _commit,
              ),
            ]
          : const [],
    );
  }

  @override
  Widget build(BuildContext context) {
    refreshScreenHeader();
    if (_loadingMasters) return const Center(child: CircularProgressIndicator());
    final isMobile = Responsive.isMobile(context);

    return PopScope(
      canPop: !_busy,
      child: Stack(children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 10),
            if (isMobile)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  if (canExcelUpload) OutlinedButton.icon(onPressed: _busy ? null : _downloadTemplate, icon: const Icon(Icons.download_outlined, size: 16), label: const Text('Template')),
                  if (canExcelUpload) OutlinedButton.icon(onPressed: _busy ? null : _uploadExcel, icon: const Icon(Icons.upload_file_outlined, size: 16), label: const Text('Upload Excel')),
                  FilledButton.icon(
                    onPressed: (_busy || _lines.isEmpty) ? null : _commit,
                    icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check_circle_outline),
                    label: const Text('Import'),
                  ),
                ]),
              ),
            if (_lines.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Wrap(spacing: 14, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(
                    '${_lines.length} row(s) loaded'
                    '${_matching ? " — finding suggested matches…" : ""}',
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w600),
                  ),
                  if (!_matching) ...[
                    _legendDot(AppColors.positive, 'Ready'),
                    _legendDot(Colors.orange, 'Needs a choice'),
                  ],
                ]),
              ),
            Expanded(
              child: _lines.isEmpty
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.upload_file_outlined, size: 48, color: AppColors.textSecondary),
                        const SizedBox(height: 12),
                        const Text('Upload an Excel file to get started.', style: TextStyle(color: AppColors.textSecondary)),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(onPressed: _addLine, icon: const Icon(Icons.add), label: const Text('Or add a row manually')),
                      ]),
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: isMobile
                          ? ListView.separated(
                              itemCount: _lines.length,
                              separatorBuilder: (_, __) => const SizedBox(height: 8),
                              itemBuilder: (_, i) => _buildLine(_lines[i], i, true),
                            )
                          : _buildDesktopGrid(),
                    ),
            ),
            if (_lines.isNotEmpty && !isMobile)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(onPressed: _busy ? null : _addLine, icon: const Icon(Icons.add, size: 16), label: const Text('Add Row')),
                ),
              ),
          ],
        ),
        if (_busy) _buildBusyOverlay(),
      ]),
    );
  }

  Widget _buildBusyOverlay() => Positioned.fill(
        child: Container(
          color: Colors.black.withValues(alpha: 0.35),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
              decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(10)),
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 3)),
                const SizedBox(height: 14),
                Text(
                  _progressText ?? (_uploadingExcel ? 'Reading Excel file…' : (_matching ? 'Finding suggested matches…' : 'Importing…')),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                const Text('Please don\'t close or navigate away from this screen.',
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
              ]),
            ),
          ),
        ),
      );

  // Sticky header + ListView.builder + synced horizontal scroll — proven
  // pattern from bulk_upload_products_screen.dart (fixes the "header
  // scrolls away" / "no horizontal scrollbar" / "hangs on hundreds of
  // rows" bugs that SakalScrollableTable's eager-build never handled).
  final _vController = ScrollController();
  final _hHeaderController = ScrollController();
  final _hBodyController = ScrollController();
  bool _syncingHScroll = false;

  void _syncHScroll(ScrollController source, ScrollController target) {
    if (_syncingHScroll || !target.hasClients) return;
    _syncingHScroll = true;
    target.jumpTo(source.offset);
    _syncingHScroll = false;
  }

  static const _colWidths = <double>[36, 110, 200, 100, 80, 220, 60, 150, 200, 110, 36, 36];
  static final _gridTotalWidth = _colWidths.fold<double>(0, (a, b) => a + b);

  Widget _buildDesktopGrid() {
    return Column(children: [
      SingleChildScrollView(
        controller: _hHeaderController,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: SizedBox(width: _gridTotalWidth, child: _buildHeaderRow(_colWidths)),
      ),
      Expanded(
        child: Scrollbar(
          controller: _hBodyController,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _hBodyController,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: _gridTotalWidth,
              child: Scrollbar(
                controller: _vController,
                thumbVisibility: true,
                child: ListView.builder(
                  controller: _vController,
                  itemCount: _lines.length,
                  itemExtent: 34,
                  itemBuilder: (_, i) => _buildLine(_lines[i], i, false, colWidths: _colWidths),
                ),
              ),
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _headerCell(String label, double width) => Container(
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: _gridRowVPad),
        decoration: BoxDecoration(color: AppColors.primary, border: Border.all(color: AppColors.primary)),
        child: Text(label, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: _gridFontSize, fontWeight: FontWeight.w700)),
      );

  Widget _buildHeaderRow(List<double> w) => Row(children: [
        _headerCell('#', w[0]),
        _headerCell('Client Code', w[1]),
        _headerCell('Client Name', w[2]),
        _headerCell('Nature', w[3]),
        _headerCell('Currency', w[4]),
        _headerCell('Suggested Match', w[5]),
        _headerCell('Score', w[6]),
        _headerCell('Action', w[7]),
        _headerCell('Parent Group', w[8]),
        _headerCell('New Code', w[9]),
        _headerCell('', w[10]),
        _headerCell('', w[11]),
      ]);

  InputDecoration get _cellInputDecoration => const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        border: InputBorder.none,
      );

  Widget _cell(Widget child, double width, {Color? tint}) => Container(
        width: width,
        decoration: tint == null
            ? _gridCellDecoration
            : BoxDecoration(border: Border.all(color: AppColors.border, width: 0.6), color: tint),
        child: child,
      );

  // A quiet visual cue, not a blocking validation error — a row that's
  // genuinely ready to Import (a chosen match, or a pre-mapped/manually
  // picked parent) tints faintly green; a row still needing a decision
  // before it can be imported tints faintly amber. Skip rows never tint,
  // since there's nothing to decide.
  Color? _matchCellTint(_CoaRow row) {
    if (row.action != 'MAP') return null;
    return row.suggestedAccount == null ? Colors.orange.withValues(alpha: 0.12) : AppColors.positive.withValues(alpha: 0.10);
  }

  Color? _parentCellTint(_CoaRow row) {
    if (row.action != 'CREATE') return null;
    return row.parentGroup == null ? Colors.orange.withValues(alpha: 0.12) : AppColors.positive.withValues(alpha: 0.10);
  }

  Widget _textField(TextEditingController ctrl, {bool enabled = true, TextAlign align = TextAlign.left}) => TextFormField(
        controller: ctrl,
        enabled: enabled && !_busy,
        textAlign: align,
        style: const TextStyle(fontSize: _gridFontSize),
        decoration: _cellInputDecoration,
      );

  String _accountLabel(Map<String, dynamic> a) => '[${a['account_code']}] ${a['account_name']}';

  Widget _suggestedMatchField(_CoaRow row) {
    return SakalAutocomplete<Map<String, dynamic>>(
      key: ValueKey(row.suggestedAccount?['id']),
      initialValue: TextEditingValue(text: row.suggestedAccount != null ? _accountLabel(row.suggestedAccount!) : ''),
      enabled: !_busy,
      displayStringForOption: _accountLabel,
      optionsBuilder: (v) async {
        final q = _norm(v.text);
        return _postingAccounts.where((a) {
          if ((a['account_nature'] as String?) != row.nature) return false;
          if (q.isEmpty) return true;
          return _norm(a['account_code'] as String? ?? '').contains(q) || _norm(a['account_name'] as String? ?? '').contains(q);
        }).take(50);
      },
      onSelected: (a) => setState(() { row.suggestedAccount = a; row.suggestedScore = null; if (row.action != 'SKIP') row.action = 'MAP'; }),
      decoration: _cellInputDecoration.copyWith(hintText: 'Search account…'),
      style: const TextStyle(fontSize: _gridFontSize),
    );
  }

  Widget _parentGroupField(_CoaRow row) {
    final enabled = row.action == 'CREATE' && !_busy;
    return SakalAutocomplete<Map<String, dynamic>>(
      key: ValueKey('${row.action}|${row.parentGroup?['id']}'),
      initialValue: TextEditingValue(text: row.parentGroup != null ? _accountLabel(row.parentGroup!) : ''),
      enabled: enabled,
      displayStringForOption: _accountLabel,
      optionsBuilder: (v) async {
        final q = _norm(v.text);
        return _groupAccounts.where((a) {
          if (q.isEmpty) return true;
          return _norm(a['account_code'] as String? ?? '').contains(q) || _norm(a['account_name'] as String? ?? '').contains(q);
        }).take(50);
      },
      onSelected: (a) => _onParentSelected(row, a),
      decoration: _cellInputDecoration.copyWith(hintText: 'Search group…'),
      style: const TextStyle(fontSize: _gridFontSize),
    );
  }

  Widget _actionField(_CoaRow row) => DropdownButtonFormField<String>(
        initialValue: row.action,
        isExpanded: true, isDense: true, itemHeight: null,
        style: const TextStyle(fontSize: _gridFontSize, color: AppColors.textPrimary),
        decoration: _cellInputDecoration,
        items: _actionLabels.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value, style: const TextStyle(fontSize: _gridFontSize)))).toList(),
        onChanged: _busy ? null : (v) => setState(() => row.action = v ?? 'CREATE'),
      );

  Widget _natureField(_CoaRow row) => DropdownButtonFormField<String>(
        initialValue: row.nature,
        isExpanded: true, isDense: true, itemHeight: null,
        style: const TextStyle(fontSize: _gridFontSize, color: AppColors.textPrimary),
        decoration: _cellInputDecoration,
        items: _natures.map((n) => DropdownMenuItem(value: n, child: Text(n, style: const TextStyle(fontSize: _gridFontSize)))).toList(),
        onChanged: _busy ? null : (v) => setState(() => row.nature = v ?? 'General'),
      );

  Widget _buildLine(_CoaRow row, int index, bool isMobile, {List<double>? colWidths}) {
    final scoreText = row.suggestedScore != null ? '${(row.suggestedScore! * 100).round()}%' : '';

    if (isMobile) {
      final fields = <Widget>[
        _textField(row.clientCodeCtrl), _textField(row.clientNameCtrl), _natureField(row),
        _textField(row.clientGroupCtrl), _textField(row.currencyCtrl),
        _suggestedMatchField(row), _actionField(row), _parentGroupField(row), _textField(row.newCodeCtrl, enabled: row.action == 'CREATE'),
        if (row.isParty)
          OutlinedButton.icon(onPressed: _busy ? null : () => _openPartyDetails(row), icon: const Icon(Icons.badge_outlined, size: 14), label: const Text('Party Details')),
      ];
      return SakalLineItemCard(
        title: row.clientNameCtrl.text.isEmpty ? 'New Row (#${index + 1})' : row.clientNameCtrl.text,
        onDelete: _busy ? null : () => _removeLine(row),
        fields: const [],
        body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final f in fields) ...[f, const SizedBox(height: 8)]]),
      );
    }

    final w = colWidths!;
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        width: w[0], alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: _gridRowVPad),
        decoration: _gridCellDecoration,
        child: Text('${index + 1}', style: const TextStyle(fontSize: _gridFontSize, color: AppColors.textSecondary)),
      ),
      _cell(_textField(row.clientCodeCtrl), w[1]),
      _cell(_textField(row.clientNameCtrl), w[2]),
      _cell(_natureField(row), w[3]),
      _cell(_textField(row.currencyCtrl), w[4]),
      _cell(_suggestedMatchField(row), w[5], tint: _matchCellTint(row)),
      Container(
        width: w[6], alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: _gridRowVPad),
        decoration: _gridCellDecoration,
        child: Text(scoreText, style: const TextStyle(fontSize: _gridFontSize, color: AppColors.textSecondary)),
      ),
      _cell(_actionField(row), w[7]),
      _cell(_parentGroupField(row), w[8], tint: _parentCellTint(row)),
      _cell(_textField(row.newCodeCtrl, enabled: row.action == 'CREATE'), w[9]),
      Container(
        width: w[10], decoration: _gridCellDecoration,
        child: row.isParty
            ? IconButton(padding: EdgeInsets.zero, iconSize: 14, icon: const Icon(Icons.badge_outlined), tooltip: 'Party Details', onPressed: _busy ? null : () => _openPartyDetails(row))
            : null,
      ),
      Container(
        width: w[11], decoration: _gridCellDecoration,
        child: _busy
            ? null
            : IconButton(padding: EdgeInsets.zero, iconSize: 14, icon: const Icon(Icons.close), tooltip: 'Remove row', onPressed: () => _removeLine(row)),
      ),
    ]);
  }
}

extension _NullIfEmptyC on String {
  String? get nullIfEmptyC => isEmpty ? null : this;
}
