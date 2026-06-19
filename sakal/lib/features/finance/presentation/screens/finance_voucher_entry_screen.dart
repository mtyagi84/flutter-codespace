import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/voucher_logic.dart';
import '../../../../core/widgets/offline_banner.dart';

// ── Line model ────────────────────────────────────────────────────────────────

class _VLine {
  String? accountId;
  String? accountName;
  String? accountCurrency;
  final String transNature;       // DR / CR — set by voucher type, not user-changeable
  final bool   isCashBank;        // true = line 1
  final TextEditingController amountCtrl;
  final TextEditingController remarksCtrl;
  String? invBillNo;

  _VLine({
    required this.transNature,
    this.isCashBank = false,
    this.accountId,
    this.accountName,
    this.accountCurrency,
    String amount  = '',
    String remarks = '',
    this.invBillNo,
  })  : amountCtrl  = TextEditingController(text: amount),
        remarksCtrl = TextEditingController(text: remarks);

  double get amount => double.tryParse(amountCtrl.text) ?? 0;

  void dispose() {
    amountCtrl.dispose();
    remarksCtrl.dispose();
  }
}

// ── Screen ────────────────────────────────────────────────────────────────────

class FinanceVoucherEntryScreen extends ConsumerStatefulWidget {
  /// Pre-select voucher type for a new voucher (from menu shortcut).
  final String? initialVoucherType;

  /// Load an existing voucher for view/edit.
  final String? editTransNo;

  const FinanceVoucherEntryScreen({
    super.key,
    this.initialVoucherType,
    this.editTransNo,
  });

  @override
  ConsumerState<FinanceVoucherEntryScreen> createState() =>
      _FinanceVoucherEntryScreenState();
}

class _FinanceVoucherEntryScreenState
    extends ConsumerState<FinanceVoucherEntryScreen> {

  // ── Header state ──────────────────────────────────────────────────────────

  String?   _voucherType;
  String?   _transNo;
  DateTime  _transDate    = DateTime.now();
  String?   _paymentMode;
  bool      _isOnAccount  = false;
  String?   _refNo;
  String?   _chequeNo;
  DateTime? _chequeDate;
  final _remarksCtrl = TextEditingController();
  bool _isPosted = false;

  // ── Lines ─────────────────────────────────────────────────────────────────

  List<_VLine> _lines = [];

  // ── Master data ───────────────────────────────────────────────────────────

  List<Map<String, dynamic>> _cashAccounts = [];
  List<Map<String, dynamic>> _bankAccounts = [];
  List<Map<String, dynamic>> _allAccounts  = [];
  List<Map<String, dynamic>> _paymentModes = [];
  String _baseCurrency   = '';
  String _localCurrency  = '';
  String _transCurrency  = '';
  double _baseRate       = 1.0;
  double _localRate      = 1.0;

  // ── UI state ──────────────────────────────────────────────────────────────

  bool    _loading   = true;
  String? _error;
  bool    _saving    = false;
  bool    _posting   = false;
  String? _actionError;

  // ── Voucher type metadata ─────────────────────────────────────────────────

  static const _supportedTypes = ['CRV', 'BRV', 'CPV', 'BPV'];
  static const _typeLabels = {
    'CRV': 'Cash Receipt Voucher',
    'BRV': 'Bank Receipt Voucher',
    'CPV': 'Cash Payment Voucher',
    'BPV': 'Bank Payment Voucher',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _remarksCtrl.dispose();
    for (final l in _lines) l.dispose();
    super.dispose();
  }

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> _init() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        DioClient.instance.get('/rim_accounts', queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false',
          'is_active':  'eq.true',
          'select':     'id,account_name,account_nature,currency_id',
          'order':      'account_name.asc',
          'limit':      '500',
        }),
        DioClient.instance.get('/rim_payment_modes', queryParameters: {
          'is_active':  'eq.true',
          'is_deleted': 'eq.false',
          'select':     'payment_mode_code,payment_mode_name',
          'or':         '(is_system.eq.true,and(client_id.eq.${session.clientId},company_id.eq.${session.companyId}))',
          'order':      'payment_mode_name.asc',
        }),
        DioClient.instance.get('/ric_companies', queryParameters: {
          'id':     'eq.${session.companyId}',
          'select': 'base_currency,local_currency',
          'limit':  '1',
        }),
      ]);

      final accounts = List<Map<String, dynamic>>.from(results[0].data as List);
      final modes    = List<Map<String, dynamic>>.from(results[1].data as List);
      final coList   = List<Map<String, dynamic>>.from(results[2].data as List);
      final co       = coList.isNotEmpty ? coList.first : <String, dynamic>{};

      if (!mounted) return;
      setState(() {
        _cashAccounts  = accounts.where((a) => a['account_nature'] == 'Cash').toList();
        _bankAccounts  = accounts.where((a) => a['account_nature'] == 'Bank').toList();
        _allAccounts   = accounts;
        _paymentModes  = modes;
        _baseCurrency  = co['base_currency']  as String? ?? '';
        _localCurrency = co['local_currency'] as String? ?? '';
      });

      if (widget.editTransNo != null) {
        await _loadExisting(widget.editTransNo!);
      } else {
        if (widget.initialVoucherType != null) _applyVoucherType(widget.initialVoucherType!);
        setState(() => _loading = false);
      }
    } on DioException {
      if (mounted) setState(() { _loading = false; _error = 'Could not load data. Check connection.'; });
    }
  }

  // ── Apply voucher type — resets lines ─────────────────────────────────────

  void _applyVoucherType(String type) {
    for (final l in _lines) l.dispose();
    final n1 = line1Nature(type);
    final n2 = counterNature(n1);
    // Default payment mode to CASH for cash vouchers
    final defaultMode = isCashVoucher(type) ? 'CASH' : null;
    setState(() {
      _voucherType  = type;
      _paymentMode  = defaultMode;
      _transCurrency = '';
      _baseRate     = 1.0;
      _lines = [
        _VLine(transNature: n1, isCashBank: true),
        _VLine(transNature: n2),
      ];
    });
  }

  // ── Load existing voucher ─────────────────────────────────────────────────

  Future<void> _loadExisting(String transNo) async {
    final session = ref.read(sessionProvider)!;
    try {
      final results = await Future.wait([
        DioClient.instance.get('/rih_finance_headers', queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'trans_no':   'eq.$transNo',
          'is_deleted': 'eq.false',
          'select':     '*',
          'limit':      '1',
        }),
        DioClient.instance.get('/rid_finance_lines', queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'trans_no':   'eq.$transNo',
          'is_deleted': 'eq.false',
          'select':     '*',
          'order':      'serial_no.asc',
        }),
      ]);

      final headers = List<Map<String, dynamic>>.from(results[0].data as List);
      final lineRows = List<Map<String, dynamic>>.from(results[1].data as List);
      if (headers.isEmpty || !mounted) { setState(() => _loading = false); return; }

      final h   = headers.first;
      final vt  = h['voucher_type_code'] as String;

      for (final l in _lines) l.dispose();

      final loadedLines = lineRows.asMap().entries.map((e) {
        final row = e.value;
        final isL1 = e.key == 0;
        final acc  = _allAccounts.where((a) => a['id'] == row['account_id']).firstOrNull;
        return _VLine(
          transNature:     row['trans_nature'] as String,
          isCashBank:      isL1,
          accountId:       row['account_id']    as String?,
          accountName:     acc?['account_name'] as String?,
          accountCurrency: row['trans_currency'] as String?,
          amount:          (row['trans_amount']  as num? ?? 0).toString(),
          remarks:         row['line_remarks']   as String? ?? '',
          invBillNo:       row['inv_bill_no']    as String?,
        );
      }).toList();

      setState(() {
        _voucherType  = vt;
        _transNo      = transNo;
        _transDate    = DateTime.parse(h['trans_date'] as String);
        _paymentMode  = h['payment_mode_code'] as String?;
        _isOnAccount  = h['is_on_account']     as bool?   ?? false;
        _refNo        = h['reference_no']      as String?;
        _chequeNo     = h['cheque_no']         as String?;
        _isPosted     = h['is_posted']         as bool?   ?? false;
        _remarksCtrl.text = h['remarks']       as String? ?? '';
        _lines        = loadedLines;
        _loading      = false;
        if (loadedLines.isNotEmpty) {
          _transCurrency = loadedLines.first.accountCurrency ?? '';
        }
      });
    } on DioException {
      if (mounted) setState(() { _loading = false; _error = 'Could not load voucher.'; });
    }
  }

  // ── Line 1 account selected — lock currency + fetch rate ──────────────────

  Future<void> _onLine1AccountSelected(String accountId) async {
    final acc = _allAccounts.where((a) => a['id'] == accountId).firstOrNull;
    if (acc == null) return;
    final currency = acc['currency_id'] as String? ?? _baseCurrency;
    setState(() {
      _lines[0].accountId       = accountId;
      _lines[0].accountName     = acc['account_name'] as String?;
      _lines[0].accountCurrency = currency;
      _transCurrency            = currency;
    });
    if (currency != _baseCurrency) await _fetchBaseRate(currency);
  }

  Future<void> _fetchBaseRate(String toCurrency) async {
    final session = ref.read(sessionProvider)!;
    if (session.locationId == null) return;
    try {
      final res = await DioClient.instance.post('/rpc/fn_get_exchange_rate', data: {
        'p_company_id':    session.companyId,
        'p_location_id':   session.locationId,
        'p_from_currency': _baseCurrency,
        'p_to_currency':   toCurrency,
        'p_rate_date':     _fmtDate(_transDate),
        'p_rate_type':     'MID',
      });
      if (mounted) setState(() => _baseRate = (res.data as num?)?.toDouble() ?? 1.0);
    } on DioException { /* rate not found — stay at 1.0 */ }
  }

  // ── Amount changed on line 1 — mirror to line 2 when 2-line voucher ───────

  void _onAmountChanged() {
    if (_lines.length == 2) {
      _lines[1].amountCtrl.text = _lines[0].amountCtrl.text;
    }
    setState(() {});
  }

  // ── Add / remove counterpart lines (On Account only) ──────────────────────

  void _addLine() {
    if (_voucherType == null) return;
    setState(() => _lines.add(_VLine(
      transNature: counterNature(line1Nature(_voucherType!)),
    )));
  }

  void _removeLine(int index) {
    if (index <= 1) return; // keep line 1 and at least line 2
    final removed = _lines.removeAt(index);
    removed.dispose();
    setState(() {});
  }

  // ── Computed totals ───────────────────────────────────────────────────────

  double get _drTotal => _lines
      .where((l) => l.transNature == 'DR')
      .fold(0.0, (s, l) => s + l.amount);

  double get _crTotal => _lines
      .where((l) => l.transNature == 'CR')
      .fold(0.0, (s, l) => s + l.amount);

  bool get _isBalanced => isVoucherBalanced(_drTotal, _crTotal);

  // ── Save draft ────────────────────────────────────────────────────────────

  Future<bool> _saveDraft() async {
    final session = ref.read(sessionProvider)!;
    if (_voucherType == null) {
      _showSnack('Select a voucher type first.');
      return false;
    }
    if (_lines.any((l) => l.accountId == null)) {
      _showSnack('All lines must have an account selected.');
      return false;
    }
    setState(() { _saving = true; _actionError = null; });
    try {
      final header = {
        'client_id':         session.clientId,
        'company_id':        session.companyId,
        'location_id':       session.locationId,
        'trans_no':          _transNo ?? '',
        'trans_date':        _fmtDate(_transDate),
        'voucher_type_code': _voucherType,
        'payment_mode_code': _paymentMode ?? '',
        'is_on_account':     _isOnAccount,
        'reference_no':      _refNo ?? '',
        'cheque_no':         _chequeNo ?? '',
        'cheque_date':       _chequeDate != null ? _fmtDate(_chequeDate!) : '',
        'remarks':           _remarksCtrl.text,
      };

      final lines = _lines.asMap().entries.map((e) {
        final idx = e.key;
        final l   = e.value;
        final amt = l.amount;
        final tc  = _transCurrency.isEmpty ? _baseCurrency : _transCurrency;
        final baseAmt  = toBaseAmount(amt, _baseRate, tc, _baseCurrency);
        final localAmt = toLocalAmount(amt, _baseRate, _localRate, tc, _localCurrency);
        return {
          'serial_no':     idx + 1,
          'account_id':    l.accountId,
          'trans_nature':  l.transNature,
          'trans_amount':  amt,
          'trans_currency': tc,
          'base_amount':   baseAmt,
          'base_rate':     _baseRate,
          'local_amount':  localAmt,
          'local_rate':    _localRate,
          'party_amount':  amt,
          'party_currency': tc,
          'party_rate':    1.0,
          'inv_bill_no':   l.invBillNo ?? '',
          'inv_bill_date': '',
          'line_remarks':  l.remarksCtrl.text,
        };
      }).toList();

      final res = await DioClient.instance.post(
        '/rpc/fn_save_finance_voucher',
        data: {'p_header': header, 'p_lines': lines, 'p_user_id': session.userId},
      );

      if (mounted) {
        setState(() { _transNo = res.data as String?; _saving = false; });
        _showSnack('Draft saved — $_transNo', color: AppColors.positive);
        return true;
      }
    } on DioException catch (e) {
      if (mounted) setState(() {
        _saving      = false;
        _actionError = 'Save failed: ${e.response?.data ?? e.message}';
      });
    }
    return false;
  }

  // ── Post voucher ──────────────────────────────────────────────────────────

  Future<void> _postVoucher() async {
    if (!_isBalanced) { _showSnack('Voucher is not balanced — DR must equal CR.'); return; }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Post Voucher'),
        content: const Text('Once posted this voucher is locked permanently. Continue?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.secondary),
            child: const Text('Post'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    if (_transNo == null) {
      final saved = await _saveDraft();
      if (!saved) return;
    }

    final session = ref.read(sessionProvider)!;
    setState(() { _posting = true; _actionError = null; });
    try {
      await DioClient.instance.post('/rpc/fn_post_finance_voucher', data: {
        'p_client_id':   session.clientId,
        'p_company_id':  session.companyId,
        'p_location_id': session.locationId,
        'p_trans_no':    _transNo,
        'p_posted_by':   session.userId,
      });
      if (mounted) {
        setState(() { _isPosted = true; _posting = false; });
        _showSnack('$_transNo posted successfully.', color: AppColors.positive);
      }
    } on DioException catch (e) {
      if (mounted) setState(() {
        _posting     = false;
        _actionError = 'Post failed: ${e.response?.data ?? e.message}';
      });
    }
  }

  // ── Date picker ───────────────────────────────────────────────────────────

  Future<void> _pickDate(DateTime current, ValueChanged<DateTime> onPicked) async {
    final d = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2020),
      lastDate: DateTime(2099),
    );
    if (d != null) onPicked(d);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';

  String _displayDate(DateTime d) {
    const m = ['','Jan','Feb','Mar','Apr','May','Jun',
        'Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day.toString().padLeft(2,'0')} ${m[d.month]} ${d.year}';
  }

  void _showSnack(String msg, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  List<Map<String, dynamic>> get _line1Accounts =>
      _voucherType == null ? [] :
      isCashVoucher(_voucherType!) ? _cashAccounts : _bankAccounts;

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final session   = ref.watch(sessionProvider);
    final isOffline = session?.offlineMode ?? false;
    final locked    = _isPosted || isOffline;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isOffline) const OfflineBanner(),

        // ── Page header ──────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                _transNo != null
                    ? '${_typeLabels[_voucherType] ?? 'Voucher'}  ·  $_transNo'
                    : _voucherType != null
                        ? 'New ${_typeLabels[_voucherType] ?? 'Voucher'}'
                        : 'New Finance Voucher',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700,
                    color: AppColors.primary),
              ),
              const SizedBox(height: 2),
              if (_isPosted)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.positive.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: AppColors.positive.withOpacity(0.4)),
                  ),
                  child: const Text('POSTED — read only',
                      style: TextStyle(fontSize: 11, color: AppColors.positive,
                          fontWeight: FontWeight.w600)),
                )
              else
                Text(_transNo != null ? 'Draft' : 'Unsaved draft',
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            ])),
          ]),
        ),

        const Divider(height: 20),

        // ── Body ─────────────────────────────────────────────────────────────
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_error != null) ...[
                        _errorBanner(_error!),
                        const SizedBox(height: 16),
                      ],
                      _buildHeaderCard(locked),
                      const SizedBox(height: 20),
                      _buildLinesSection(locked),
                      const SizedBox(height: 12),
                      _buildTotalsBar(),
                      if (_actionError != null) ...[
                        const SizedBox(height: 12),
                        _errorBanner(_actionError!),
                      ],
                      if (!locked) ...[
                        const SizedBox(height: 20),
                        _buildButtons(),
                      ],
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  // ── Header card ───────────────────────────────────────────────────────────

  Widget _buildHeaderCard(bool locked) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [

          // Row 1: Voucher Type | Trans No | Date
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              flex: 3,
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: 'Voucher Type *',
                    border: OutlineInputBorder(), isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                value: _voucherType,
                isExpanded: true,
                items: _supportedTypes.map((t) => DropdownMenuItem(
                  value: t,
                  child: Text('$t — ${_typeLabels[t]}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13)),
                )).toList(),
                onChanged: locked ? null : (v) { if (v != null) _applyVoucherType(v); },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: InputDecorator(
                decoration: const InputDecoration(labelText: 'Trans No',
                    border: OutlineInputBorder(), isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                child: Text(
                  _transNo ?? '(auto on save)',
                  style: TextStyle(fontSize: 13,
                      color: _transNo != null ? AppColors.textPrimary : AppColors.textDisabled),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: InkWell(
                onTap: locked ? null
                    : () => _pickDate(_transDate, (d) => setState(() => _transDate = d)),
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: 'Date *',
                    border: const OutlineInputBorder(), isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    suffixIcon: Icon(Icons.calendar_today_outlined, size: 15,
                        color: locked ? AppColors.textDisabled : AppColors.primary),
                  ),
                  child: Text(_displayDate(_transDate), style: const TextStyle(fontSize: 13)),
                ),
              ),
            ),
          ]),

          const SizedBox(height: 12),

          // Row 2: Payment Mode | On Account / Against Invoice
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Expanded(
              flex: 2,
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: 'Payment Mode',
                    border: OutlineInputBorder(), isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                value: _paymentMode,
                items: _paymentModes.map((m) => DropdownMenuItem(
                  value: m['payment_mode_code'] as String,
                  child: Text(m['payment_mode_name'] as String,
                      style: const TextStyle(fontSize: 13)),
                )).toList(),
                onChanged: locked ? null : (v) => setState(() => _paymentMode = v),
              ),
            ),
            const SizedBox(width: 24),
            Row(children: [
              Radio<bool>(value: false, groupValue: _isOnAccount,
                  onChanged: locked ? null : (_) => setState(() => _isOnAccount = false)),
              const Text('Against Invoice', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 16),
              Radio<bool>(value: true, groupValue: _isOnAccount,
                  onChanged: locked ? null : (_) => setState(() => _isOnAccount = true)),
              const Text('On Account', style: TextStyle(fontSize: 13)),
            ]),
          ]),

          // Cheque fields — only when CHEQUE mode
          if (_paymentMode == 'CHEQUE') ...[
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: TextFormField(
                  enabled: !locked,
                  initialValue: _chequeNo,
                  decoration: const InputDecoration(labelText: 'Cheque No',
                      border: OutlineInputBorder(), isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                  style: const TextStyle(fontSize: 13),
                  onChanged: (v) => _chequeNo = v.isEmpty ? null : v,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: InkWell(
                  onTap: locked ? null
                      : () => _pickDate(_chequeDate ?? _transDate,
                              (d) => setState(() => _chequeDate = d)),
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Cheque Date',
                      border: const OutlineInputBorder(), isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      suffixIcon: Icon(Icons.calendar_today_outlined, size: 15,
                          color: locked ? AppColors.textDisabled : AppColors.primary),
                    ),
                    child: Text(
                      _chequeDate != null ? _displayDate(_chequeDate!) : 'Select date',
                      style: TextStyle(fontSize: 13,
                          color: _chequeDate != null
                              ? AppColors.textPrimary : AppColors.textDisabled),
                    ),
                  ),
                ),
              ),
            ]),
          ],

          const SizedBox(height: 12),

          // Row 3: Ref No | Remarks
          Row(children: [
            Expanded(
              child: TextFormField(
                enabled: !locked,
                initialValue: _refNo,
                decoration: const InputDecoration(labelText: 'Reference No',
                    border: OutlineInputBorder(), isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                style: const TextStyle(fontSize: 13),
                onChanged: (v) => _refNo = v.isEmpty ? null : v,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: TextFormField(
                enabled: !locked,
                controller: _remarksCtrl,
                decoration: const InputDecoration(labelText: 'Remarks',
                    border: OutlineInputBorder(), isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  // ── Lines section ─────────────────────────────────────────────────────────

  Widget _buildLinesSection(bool locked) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('Journal Lines',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
                color: AppColors.primary)),
        const Spacer(),
        if (!locked && _isOnAccount && _voucherType != null)
          TextButton.icon(
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add Line'),
            onPressed: _addLine,
          ),
      ]),
      const SizedBox(height: 6),

      // Table header
      Container(
        decoration: const BoxDecoration(
          color: AppColors.primary,
          borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
        ),
        child: Row(children: [
          _th('#',         width: 36),
          _th('Account',   flex: 3),
          _th('DR',        flex: 2, align: TextAlign.right),
          _th('CR',        flex: 2, align: TextAlign.right),
          _th('Remarks',   flex: 2),
          if (!locked) const SizedBox(width: 36),
        ]),
      ),

      // Lines
      Container(
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.border),
          borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
        ),
        child: Column(
          children: [
            for (int i = 0; i < _lines.length; i++) ...[
              if (i > 0) Divider(height: 1, color: AppColors.border),
              _buildLineRow(i, locked),
            ],
          ],
        ),
      ),
    ]);
  }

  Widget _th(String t, {double? width, int flex = 1, TextAlign align = TextAlign.left}) {
    final child = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      child: Text(t, textAlign: align,
          style: const TextStyle(color: Colors.white,
              fontWeight: FontWeight.w600, fontSize: 12)),
    );
    if (width != null) return SizedBox(width: width, child: child);
    return Expanded(flex: flex, child: child);
  }

  Widget _buildLineRow(int idx, bool locked) {
    final line   = _lines[idx];
    final isLine1 = idx == 0;
    final accounts = isLine1 ? _line1Accounts : _allAccounts;

    return StatefulBuilder(
      builder: (_, setRow) => Container(
        color: isLine1 ? AppColors.primary.withOpacity(0.04) : Colors.white,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // # serial
          SizedBox(
            width: 36,
            child: Padding(
              padding: const EdgeInsets.only(top: 14, left: 8),
              child: Text('${idx + 1}',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                      color: isLine1 ? AppColors.primary : AppColors.textSecondary)),
            ),
          ),

          // Account + invoice field
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                DropdownButtonFormField<String>(
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(), isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    hintText: isLine1 ? 'Select Cash/Bank account' : 'Select account',
                    hintStyle: const TextStyle(fontSize: 12, color: AppColors.textDisabled),
                  ),
                  value: line.accountId,
                  isExpanded: true,
                  items: accounts.map((a) => DropdownMenuItem(
                    value: a['id'] as String,
                    child: Text(a['account_name'] as String,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13)),
                  )).toList(),
                  onChanged: locked ? null : (v) async {
                    if (v == null) return;
                    if (isLine1) {
                      await _onLine1AccountSelected(v);
                      setRow(() {});
                    } else {
                      final acc = _allAccounts
                          .where((a) => a['id'] == v).firstOrNull;
                      setState(() {
                        line.accountId   = v;
                        line.accountName = acc?['account_name'] as String?;
                      });
                    }
                  },
                ),
                // Invoice No field — Against Invoice + non-line-1
                if (!_isOnAccount && !isLine1) ...[
                  const SizedBox(height: 4),
                  TextFormField(
                    enabled: !locked,
                    initialValue: line.invBillNo,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                      hintText: 'Invoice / Bill No',
                      border: OutlineInputBorder(), isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      hintStyle: TextStyle(fontSize: 11, color: AppColors.textDisabled),
                      prefixIcon: Icon(Icons.receipt_outlined, size: 14),
                    ),
                    onChanged: (v) => line.invBillNo = v.isEmpty ? null : v,
                  ),
                ],
              ]),
            ),
          ),

          // DR column
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: line.transNature == 'DR'
                  ? _amountField(line.amountCtrl, locked, onChange: (_) {
                      setRow(() {});
                      if (isLine1) _onAmountChanged();
                    })
                  : _blankCell(),
            ),
          ),

          // CR column
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: line.transNature == 'CR'
                  ? _amountField(line.amountCtrl, locked, onChange: (_) {
                      setRow(() {});
                      if (isLine1) _onAmountChanged();
                    })
                  : _blankCell(),
            ),
          ),

          // Remarks — party lines only
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: !isLine1
                  ? TextFormField(
                      enabled: !locked,
                      controller: line.remarksCtrl,
                      style: const TextStyle(fontSize: 12),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(), isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                        hintText: 'Remark',
                        hintStyle: TextStyle(fontSize: 11),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),

          // Remove button (line 3+ only)
          if (!locked)
            SizedBox(
              width: 36,
              child: idx > 1
                  ? IconButton(
                      icon: const Icon(Icons.remove_circle_outline, size: 18),
                      color: AppColors.negative,
                      onPressed: () => _removeLine(idx),
                      padding: const EdgeInsets.all(8),
                      tooltip: 'Remove line',
                    )
                  : const SizedBox.shrink(),
            ),
        ]),
      ),
    );
  }

  Widget _amountField(TextEditingController ctrl, bool locked,
      {required ValueChanged<String> onChange}) {
    return TextFormField(
      controller: ctrl,
      enabled: !locked,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
      onChanged: onChange,
      textAlign: TextAlign.right,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      decoration: const InputDecoration(
        border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      ),
    );
  }

  Widget _blankCell() => Container(
    height: 36,
    decoration: BoxDecoration(
      color: AppColors.surfaceVariant,
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: AppColors.border),
    ),
    alignment: Alignment.center,
    child: const Text('—', style: TextStyle(color: AppColors.textDisabled)),
  );

  // ── Totals bar ────────────────────────────────────────────────────────────

  Widget _buildTotalsBar() {
    final balanced = _isBalanced;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: balanced
            ? AppColors.positive.withOpacity(0.06)
            : AppColors.negative.withOpacity(0.06),
        border: Border.all(
          color: balanced
              ? AppColors.positive.withOpacity(0.3)
              : AppColors.negative.withOpacity(0.3),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        Text('DR: ${_drTotal.toStringAsFixed(2)}',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        const SizedBox(width: 24),
        Text('CR: ${_crTotal.toStringAsFixed(2)}',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        if (_transCurrency.isNotEmpty) ...[
          const SizedBox(width: 8),
          Text('($_transCurrency)',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        ],
        const Spacer(),
        Icon(
          balanced ? Icons.check_circle_outline : Icons.warning_amber_outlined,
          size: 18,
          color: balanced ? AppColors.positive : AppColors.negative,
        ),
        const SizedBox(width: 6),
        Text(
          balanced ? 'Balanced' : 'Not balanced',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13,
              color: balanced ? AppColors.positive : AppColors.negative),
        ),
      ]),
    );
  }

  // ── Action buttons ────────────────────────────────────────────────────────

  Widget _buildButtons() {
    return Row(children: [
      OutlinedButton.icon(
        icon: _saving
            ? const SizedBox(width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.save_outlined, size: 16),
        label: Text(_saving ? 'Saving…' : 'Save Draft'),
        onPressed: (_saving || _posting) ? null : _saveDraft,
        style: OutlinedButton.styleFrom(minimumSize: const Size(140, 44)),
      ),
      const SizedBox(width: 12),
      FilledButton.icon(
        icon: _posting
            ? const SizedBox(width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.check_circle_outline, size: 16),
        label: Text(_posting ? 'Posting…' : 'Post Voucher'),
        onPressed: (_saving || _posting) ? null : _postVoucher,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.secondary,
          minimumSize: const Size(140, 44),
        ),
      ),
    ]);
  }

  // ── Error banner ──────────────────────────────────────────────────────────

  Widget _errorBanner(String msg) => Container(
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
      Expanded(child: Text(msg,
          style: const TextStyle(color: AppColors.negative, fontSize: 13))),
    ]),
  );
}
