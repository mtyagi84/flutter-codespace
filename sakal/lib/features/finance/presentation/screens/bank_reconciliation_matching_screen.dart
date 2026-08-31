import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/layout/screen_header.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';

class _BookLine {
  final String financeLineId;
  final String transNo;
  final String transDate;
  final String voucherTypeCode;
  final String transNature;
  final double baseAmount;
  final String remarks;
  bool selected = false;

  _BookLine.fromJson(Map<String, dynamic> j)
      : financeLineId = j['finance_line_id'] as String,
        transNo = j['trans_no'] as String? ?? '',
        transDate = j['trans_date'] as String? ?? '',
        voucherTypeCode = j['voucher_type_code'] as String? ?? '',
        transNature = j['trans_nature'] as String? ?? '',
        baseAmount = (j['base_amount'] as num? ?? 0).toDouble(),
        remarks = j['line_remarks'] as String? ?? '';
}

class _StatementLine {
  final String bankStatementLineId;
  final String statementNo;
  final String statementDate;
  final String txnNo;
  final String txnDate;
  final String remarks;
  final double debitAmount;
  final double creditAmount;
  bool selected = false;

  _StatementLine.fromJson(Map<String, dynamic> j)
      : bankStatementLineId = j['bank_statement_line_id'] as String,
        statementNo = j['statement_no'] as String? ?? '',
        statementDate = j['statement_date'] as String? ?? '',
        txnNo = j['txn_no'] as String? ?? '',
        txnDate = j['txn_date'] as String? ?? '',
        remarks = j['remarks'] as String? ?? '',
        debitAmount = (j['debit_amount'] as num? ?? 0).toDouble(),
        creditAmount = (j['credit_amount'] as num? ?? 0).toDouble();

  double get amount => debitAmount > 0 ? debitAmount : creditAmount;
}

/// Bank Reconciliation Matching — see docs/screens/bank_reconciliation_matching.md.
class BankReconciliationMatchingScreen extends ConsumerStatefulWidget {
  const BankReconciliationMatchingScreen({super.key});

  @override
  ConsumerState<BankReconciliationMatchingScreen> createState() => _BankReconciliationMatchingScreenState();
}

class _BankReconciliationMatchingScreenState extends ConsumerState<BankReconciliationMatchingScreen>
    with ScreenPermissionMixin<BankReconciliationMatchingScreen>, ScreenHeaderMixin<BankReconciliationMatchingScreen> {
  @override String get screenName => RouteNames.bankStatements;

  @override
  ScreenHeaderInfo buildScreenHeader() => const ScreenHeaderInfo(title: 'Bank Reconciliation');

  List<Map<String, dynamic>> _bankAccounts = [];
  String? _bankAccountId;
  DateTime _dateFrom = DateTime.now().subtract(const Duration(days: 90));
  DateTime _dateTo = DateTime.now();
  String _baseCurrency = '';

  List<_BookLine> _bookLines = [];
  List<_StatementLine> _statementLines = [];
  Map<String, dynamic>? _summary;

  bool _loadingAccounts = true;
  bool _loadingLines = false;
  bool _matching = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initAccounts());
  }

  Future<void> _initAccounts() async {
    final session = ref.read(sessionProvider)!;
    try {
      final results = await Future.wait([
        DioClient.instance.get('/rim_bank_accounts', queryParameters: {
          'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
          'is_active': 'eq.true', 'is_deleted': 'eq.false',
          'select': 'id,bank_name,account_id,account:rim_accounts!account_id(account_code,account_name)',
          'order': 'bank_name.asc',
        }),
        DioClient.instance.get('/ric_companies', queryParameters: {
          'id': 'eq.${session.companyId}', 'select': 'base_currency', 'limit': '1',
        }),
      ]);
      if (mounted) {
        setState(() {
          _bankAccounts = List<Map<String, dynamic>>.from(results[0].data as List);
          final companies = List<Map<String, dynamic>>.from(results[1].data as List);
          _baseCurrency = companies.isNotEmpty ? companies.first['base_currency'] as String? ?? '' : '';
          _loadingAccounts = false;
        });
      }
    } catch (e, st) {
      AppLogger.error('BankReconciliationInit', e, st);
      if (mounted) setState(() { _loadingAccounts = false; _error = ErrorPresenter.format(e, action: 'load bank accounts'); });
    }
  }

  String _fmtDate(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    if (_bankAccountId == null) {
      _showSnack('Select a Bank Account first.', color: AppColors.negative);
      return;
    }
    final session = ref.read(sessionProvider)!;
    setState(() { _loadingLines = true; _error = null; });
    try {
      final results = await Future.wait([
        DioClient.instance.get('/v_bank_reconciliation_book_lines', queryParameters: {
          'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
          'bank_account_id': 'eq.$_bankAccountId',
          'trans_date': ['gte.${_fmtDate(_dateFrom)}', 'lte.${_fmtDate(_dateTo)}'],
          'order': 'trans_date.asc',
        }),
        DioClient.instance.get('/v_bank_reconciliation_statement_lines', queryParameters: {
          'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
          'bank_account_id': 'eq.$_bankAccountId',
          'txn_date': ['gte.${_fmtDate(_dateFrom)}', 'lte.${_fmtDate(_dateTo)}'],
          'order': 'txn_date.asc',
        }),
        DioClient.instance.post('/rpc/fn_bank_reconciliation_summary', data: {
          'p_client_id': session.clientId, 'p_company_id': session.companyId,
          'p_bank_account_id': _bankAccountId, 'p_as_of_date': _fmtDate(_dateTo),
        }),
      ]);
      if (mounted) {
        setState(() {
          _bookLines = (results[0].data as List).map((j) => _BookLine.fromJson(j as Map<String, dynamic>)).toList();
          _statementLines = (results[1].data as List).map((j) => _StatementLine.fromJson(j as Map<String, dynamic>)).toList();
          final summaryList = results[2].data as List;
          _summary = summaryList.isNotEmpty ? summaryList.first as Map<String, dynamic> : null;
          _loadingLines = false;
        });
      }
    } catch (e, st) {
      AppLogger.error('BankReconciliationLoad', e, st);
      if (mounted) setState(() { _loadingLines = false; _error = ErrorPresenter.format(e, action: 'load reconciliation data'); });
    }
  }

  void _showSnack(String msg, {required Color color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  double get _selectedBookTotal => _bookLines.where((l) => l.selected).fold(0.0, (s, l) => s + l.baseAmount);
  double get _selectedStatementTotal => _statementLines.where((l) => l.selected).fold(0.0, (s, l) => s + l.amount);
  bool get _hasSelection => _bookLines.any((l) => l.selected) || _statementLines.any((l) => l.selected);
  bool get _canMatch => _hasSelection && (_selectedBookTotal - _selectedStatementTotal).abs() < 0.01;

  Future<void> _match() async {
    final session = ref.read(sessionProvider)!;
    setState(() => _matching = true);
    try {
      await DioClient.instance.post('/rpc/fn_create_reconciliation_match', data: {
        'p_client_id': session.clientId, 'p_company_id': session.companyId,
        'p_bank_account_id': _bankAccountId,
        'p_finance_line_ids': _bookLines.where((l) => l.selected).map((l) => l.financeLineId).toList(),
        'p_statement_line_ids': _statementLines.where((l) => l.selected).map((l) => l.bankStatementLineId).toList(),
        'p_match_type': 'MANUAL', 'p_user_id': session.userId,
      });
      _showSnack('Matched.', color: AppColors.positive);
      await _load();
    } catch (e, st) {
      AppLogger.error('BankReconciliationMatch', e, st);
      _showSnack(ErrorPresenter.format(e, action: 'create this match'), color: AppColors.negative);
    } finally {
      if (mounted) setState(() => _matching = false);
    }
  }

  Future<void> _autoMatch() async {
    final session = ref.read(sessionProvider)!;
    setState(() => _matching = true);
    try {
      final res = await DioClient.instance.post('/rpc/fn_auto_match_bank_statement', data: {
        'p_client_id': session.clientId, 'p_company_id': session.companyId,
        'p_bank_account_id': _bankAccountId,
        'p_date_from': _fmtDate(_dateFrom), 'p_date_to': _fmtDate(_dateTo),
        'p_user_id': session.userId,
      });
      final list = res.data as List;
      final count = list.isNotEmpty ? (list.first as Map<String, dynamic>)['matched_pairs'] as int? ?? 0 : 0;
      _showSnack('$count pair(s) auto-matched.', color: AppColors.positive);
      await _load();
    } catch (e, st) {
      AppLogger.error('BankReconciliationAutoMatch', e, st);
      _showSnack(ErrorPresenter.format(e, action: 'auto-match this statement'), color: AppColors.negative);
    } finally {
      if (mounted) setState(() => _matching = false);
    }
  }

  Future<void> _quickEntry(_StatementLine line) async {
    final session = ref.read(sessionProvider)!;
    // Load posting-allowed accounts once per dialog open — a small master
    // list, fine to fetch fresh each time given this is an occasional action.
    final accountsRes = await DioClient.instance.get('/rim_accounts', queryParameters: {
      'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
      'posting_allowed': 'eq.true', 'is_deleted': 'eq.false',
      'select': 'id,account_code,account_name', 'order': 'account_name.asc',
    });
    final accounts = List<Map<String, dynamic>>.from(accountsRes.data as List);

    String? counterpartAccountId;
    final amountCtrl = TextEditingController(text: line.amount.toStringAsFixed(2));
    final narrationCtrl = TextEditingController(text: line.remarks);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Book This Statement Line'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                'Posts a simple Journal Voucher in ${_baseCurrency.isEmpty ? 'base currency' : _baseCurrency} — '
                'use the full Journal/Payment/Receipt Voucher screen for anything needing a different currency.',
                style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: counterpartAccountId,
                isExpanded: true, isDense: true, itemHeight: null,
                decoration: const InputDecoration(labelText: 'Counterpart Account *'),
                items: accounts.map((a) => DropdownMenuItem(value: a['id'] as String, child: Text('[${a['account_code']}] ${a['account_name']}', overflow: TextOverflow.ellipsis))).toList(),
                onChanged: (v) => setDialogState(() => counterpartAccountId = v),
              ),
              const SizedBox(height: 10),
              TextField(controller: amountCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount *')),
              const SizedBox(height: 10),
              TextField(controller: narrationCtrl, decoration: const InputDecoration(labelText: 'Narration')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(true), child: const Text('Post')),
          ],
        ),
      ),
    );

    if (confirmed != true || counterpartAccountId == null) return;
    final amount = double.tryParse(amountCtrl.text.trim()) ?? 0;
    if (amount <= 0) {
      _showSnack('Enter a valid amount.', color: AppColors.negative);
      return;
    }

    final bankAccount = _bankAccounts.firstWhere((a) => a['id'] == _bankAccountId);
    final bankLedgerAccountId = bankAccount['account_id'] as String;
    // A CREDIT on the statement (money the bank received) means our Bank
    // ledger should be debited (asset increase); a DEBIT on the statement
    // means our Bank ledger should be credited.
    final bankNature = line.creditAmount > 0 ? 'DR' : 'CR';
    final counterpartNature = bankNature == 'DR' ? 'CR' : 'DR';

    try {
      final session2 = ref.read(sessionProvider)!;
      Map<String, dynamic> buildLine(String accountId, String nature) => {
            'account_id': accountId, 'trans_nature': nature,
            'trans_amount': amount, 'trans_currency': _baseCurrency,
            'base_amount': amount, 'base_rate': 1,
            'local_amount': amount, 'local_rate': 1,
            'party_amount': amount, 'party_currency': _baseCurrency, 'party_rate': 1,
          };

      final header = {
        'client_id': session2.clientId, 'company_id': session2.companyId,
        'location_id': session2.locationId,
        'voucher_type_code': 'JV',
        'trans_date': line.txnDate,
        'remarks': narrationCtrl.text.trim().isEmpty ? 'Bank reconciliation entry' : narrationCtrl.text.trim(),
      };
      final lines = [buildLine(bankLedgerAccountId, bankNature), buildLine(counterpartAccountId!, counterpartNature)];

      final saveRes = await DioClient.instance.post('/rpc/fn_save_finance_voucher', data: {
        'p_header': header, 'p_lines': lines, 'p_user_id': session2.userId,
      });
      final transNo = saveRes.data as String;

      await DioClient.instance.post('/rpc/fn_post_finance_voucher', data: {
        'p_client_id': session2.clientId, 'p_company_id': session2.companyId,
        'p_location_id': session2.locationId, 'p_trans_no': transNo,
        'p_trans_date': header['trans_date'], 'p_posted_by': session2.userId,
      });

      _showSnack('Posted as $transNo — reload to match it.', color: AppColors.positive);
      await _load();
    } catch (e, st) {
      AppLogger.error('BankReconciliationQuickEntry', e, st);
      _showSnack(ErrorPresenter.format(e, action: 'post this entry'), color: AppColors.negative);
    } finally {
      amountCtrl.dispose();
      narrationCtrl.dispose();
    }
  }

  Future<void> _pickDate({required bool isFrom}) async {
    final picked = await showDatePicker(
      context: context, initialDate: isFrom ? _dateFrom : _dateTo,
      firstDate: DateTime(2020), lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => isFrom ? _dateFrom = picked : _dateTo = picked);
  }

  @override
  Widget build(BuildContext context) {
    refreshScreenHeader();
    if (_loadingAccounts) return const Center(child: CircularProgressIndicator());

    final isMobile = Responsive.isMobile(context);

    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(14),
        child: Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(
            width: isMobile ? double.infinity : 260,
            child: DropdownButtonFormField<String>(
              initialValue: _bankAccountId,
              isExpanded: true, isDense: true, itemHeight: null,
              decoration: const InputDecoration(labelText: 'Bank Account'),
              items: _bankAccounts.map((a) => DropdownMenuItem(value: a['id'] as String, child: Text(a['bank_name'] as String, overflow: TextOverflow.ellipsis))).toList(),
              onChanged: (v) => setState(() => _bankAccountId = v),
            ),
          ),
          SizedBox(
            width: isMobile ? double.infinity : 160,
            child: InkWell(
              onTap: () => _pickDate(isFrom: true),
              child: InputDecorator(decoration: const InputDecoration(labelText: 'From Date'), child: Text(_fmtDate(_dateFrom))),
            ),
          ),
          SizedBox(
            width: isMobile ? double.infinity : 160,
            child: InkWell(
              onTap: () => _pickDate(isFrom: false),
              child: InputDecorator(decoration: const InputDecoration(labelText: 'To Date'), child: Text(_fmtDate(_dateTo))),
            ),
          ),
          FilledButton.icon(onPressed: _loadingLines ? null : _load, icon: const Icon(Icons.search, size: 16), label: const Text('Load')),
          OutlinedButton.icon(onPressed: (_loadingLines || _matching || _bankAccountId == null) ? null : _autoMatch, icon: const Icon(Icons.auto_fix_high, size: 16), label: const Text('Auto-Match')),
        ]),
      ),
      if (_error != null)
        Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: Text(_error!, style: const TextStyle(color: AppColors.negative, fontSize: 12))),
      if (_summary != null) _buildSummaryCard(),
      if (_loadingLines) const Expanded(child: Center(child: CircularProgressIndicator())),
      if (!_loadingLines && _bankAccountId != null)
        Expanded(
          child: isMobile
              ? ListView(children: [_buildBookPanel(), const Divider(), _buildStatementPanel()])
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _buildBookPanel()),
                  const VerticalDivider(width: 1),
                  Expanded(child: _buildStatementPanel()),
                ]),
        ),
      if (!_loadingLines && _bankAccountId != null) _buildMatchFooter(),
    ]);
  }

  Widget _buildSummaryCard() {
    final s = _summary!;
    double v(String k) => (s[k] as num? ?? 0).toDouble();
    final diff = v('reconciliation_diff');
    final tied = diff.abs() < 0.01;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(spacing: 20, runSpacing: 8, children: [
          _summaryStat('Adjusted Book Balance', v('adjusted_book_balance')),
          _summaryStat('Adjusted Bank Balance', v('adjusted_bank_balance')),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(tied ? Icons.check_circle : Icons.error_outline, size: 16, color: tied ? AppColors.positive : AppColors.negative),
            const SizedBox(width: 4),
            Text('Difference: ${diff.toStringAsFixed(2)}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: tied ? AppColors.positive : AppColors.negative)),
          ]),
        ]),
      ),
    );
  }

  Widget _summaryStat(String label, double value) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
        Text(value.toStringAsFixed(2), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ]);

  Widget _buildBookPanel() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Padding(padding: EdgeInsets.fromLTRB(14, 10, 14, 4), child: Text('Book Entries', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
      if (_bookLines.isEmpty) const Padding(padding: EdgeInsets.all(14), child: Text('No unreconciled book entries in this period.', style: TextStyle(color: AppColors.textSecondary, fontSize: 12))),
      ..._bookLines.map((l) => CheckboxListTile(
            dense: true,
            value: l.selected,
            onChanged: (v) => setState(() => l.selected = v ?? false),
            title: Text('${l.transNo} · ${l.transDate}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            subtitle: Text('${l.voucherTypeCode} · ${l.transNature} ${l.baseAmount.toStringAsFixed(2)}${l.remarks.isNotEmpty ? ' · ${l.remarks}' : ''}', style: const TextStyle(fontSize: 11)),
          )),
    ]);
  }

  Widget _buildStatementPanel() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Padding(padding: EdgeInsets.fromLTRB(14, 10, 14, 4), child: Text('Bank Statement Lines', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
      if (_statementLines.isEmpty) const Padding(padding: EdgeInsets.all(14), child: Text('No unreconciled statement lines in this period.', style: TextStyle(color: AppColors.textSecondary, fontSize: 12))),
      ..._statementLines.map((l) => CheckboxListTile(
            dense: true,
            value: l.selected,
            onChanged: (v) => setState(() => l.selected = v ?? false),
            title: Text('${l.txnNo.isEmpty ? l.statementNo : l.txnNo} · ${l.txnDate}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            subtitle: Text('${l.debitAmount > 0 ? 'Dr' : 'Cr'} ${l.amount.toStringAsFixed(2)}${l.remarks.isNotEmpty ? ' · ${l.remarks}' : ''}', style: const TextStyle(fontSize: 11)),
            secondary: canAdd
                ? IconButton(icon: const Icon(Icons.add_business_outlined, size: 18), tooltip: 'Book This', onPressed: () => _quickEntry(l))
                : null,
          )),
    ]);
  }

  Widget _buildMatchFooter() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.border))),
      child: Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: 12, runSpacing: 8, children: [
        Text('Selected Book: ${_selectedBookTotal.toStringAsFixed(2)}   ·   Selected Bank: ${_selectedStatementTotal.toStringAsFixed(2)}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        FilledButton.icon(
          onPressed: (_canMatch && !_matching) ? _match : null,
          icon: _matching ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.link, size: 16),
          label: const Text('Match'),
        ),
      ]),
    );
  }
}
