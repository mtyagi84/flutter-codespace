import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/voucher_logic.dart';
import '../../../../core/widgets/offline_banner.dart';

// ── Data models ───────────────────────────────────────────────────────────────

class _BillRow {
  final String  transNo;
  final String  transDate;
  final String  invBillNo;
  final String? invBillDate;
  final double  billAmount;
  final double  settledAmount;
  final double  balanceAmount;
  final String  partyCurrency;
  final TextEditingController payTransCtrl;

  _BillRow({
    required this.transNo,
    required this.transDate,
    required this.invBillNo,
    this.invBillDate,
    required this.billAmount,
    required this.settledAmount,
    required this.balanceAmount,
    required this.partyCurrency,
    double initialPay = 0,
  }) : payTransCtrl = TextEditingController(
           text: initialPay > 0 ? initialPay.toStringAsFixed(2) : '');

  double get payTrans => double.tryParse(payTransCtrl.text) ?? 0;
  void dispose() => payTransCtrl.dispose();
}

class _AccountLine {
  String? accountId;
  String? accountName;
  final TextEditingController amountCtrl;
  final TextEditingController remarksCtrl;

  _AccountLine({
    this.accountId,
    this.accountName,
    String amount  = '',
    String remarks = '',
  })  : amountCtrl  = TextEditingController(text: amount),
        remarksCtrl = TextEditingController(text: remarks);

  double get amount => double.tryParse(amountCtrl.text) ?? 0;
  void dispose() { amountCtrl.dispose(); remarksCtrl.dispose(); }
}

// ── Screen ────────────────────────────────────────────────────────────────────

class FinanceVoucherEntryScreen extends ConsumerStatefulWidget {
  final String? initialVoucherType;
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

  // ── Header ────────────────────────────────────────────────────────────────
  String?   _voucherType;
  String?   _voucherNo;
  DateTime  _transDate  = DateTime.now();
  bool      _isOnAccount = false;
  bool      _isPosted    = false;

  // ── Cash / Bank (header level) ────────────────────────────────────────────
  String?   _cashBankId;
  String?   _cashBankName;
  String    _transCurrency = '';
  final     _rateCtrl = TextEditingController(text: '1');
  double get _rate => double.tryParse(_rateCtrl.text) ?? 1.0;

  // ── Payment details ───────────────────────────────────────────────────────
  String?   _paymentMode;
  final     _refNoCtrl    = TextEditingController();
  DateTime? _refDate;
  final     _remarksCtrl  = TextEditingController();
  final     _chequeNoCtrl = TextEditingController();
  DateTime? _chequeDate;

  // ── Against Bill ──────────────────────────────────────────────────────────
  String?   _partyId;
  String?   _partyName;
  String    _partyCurrency = '';
  double    _partyRate     = 1.0;
  List<_BillRow> _bills        = [];
  bool           _loadingBills = false;

  // ── On Account ────────────────────────────────────────────────────────────
  List<_AccountLine> _accountLines = [_AccountLine()];

  // ── Master data ───────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _cashAccounts  = [];
  List<Map<String, dynamic>> _bankAccounts  = [];
  List<Map<String, dynamic>> _partyAccounts = [];
  List<Map<String, dynamic>> _otherAccounts = [];
  List<Map<String, dynamic>> _paymentModes  = [];
  String _baseCurrency  = '';
  String _localCurrency = '';
  double _localRate     = 1.0;

  // ── UI state ──────────────────────────────────────────────────────────────
  bool    _loading     = true;
  String? _error;
  bool    _saving      = false;
  bool    _posting     = false;
  String? _actionError;

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
    _rateCtrl.dispose();
    _refNoCtrl.dispose();
    _remarksCtrl.dispose();
    _chequeNoCtrl.dispose();
    for (final b in _bills) b.dispose();
    for (final l in _accountLines) l.dispose();
    super.dispose();
  }

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> _init() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        DioClient.instance.get('/rim_accounts', queryParameters: {
          'client_id':       'eq.${session.clientId}',
          'company_id':      'eq.${session.companyId}',
          'is_deleted':      'eq.false',
          'is_active':       'eq.true',
          'posting_allowed': 'eq.true',
          // Embed rim_currencies via account_currency_id FK
          'select': 'id,account_name,account_nature,'
                    'rim_currencies!account_currency_id(currency_id)',
          'order': 'account_name.asc',
          'limit': '500',
        }),
        DioClient.instance.get('/rim_payment_modes', queryParameters: {
          'is_active':  'eq.true',
          'is_deleted': 'eq.false',
          'select':     'payment_mode_code,payment_mode_name',
          'or':         '(is_system.eq.true,and(client_id.eq.${session.clientId},'
                        'company_id.eq.${session.companyId}))',
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
      final base  = co['base_currency']  as String? ?? '';
      final local = co['local_currency'] as String? ?? '';

      setState(() {
        _baseCurrency  = base;
        _localCurrency = local;
        _cashAccounts  = accounts.where((a) => a['account_nature'] == 'Cash').toList();
        _bankAccounts  = accounts.where((a) => a['account_nature'] == 'Bank').toList();
        _partyAccounts = accounts.where((a) {
          final n = a['account_nature'] as String?;
          return n == 'Customer' || n == 'Supplier';
        }).toList();
        _otherAccounts = accounts.where((a) {
          final n = a['account_nature'] as String?;
          return n != 'Cash' && n != 'Bank';
        }).toList();
        _paymentModes  = modes;
      });

      if (widget.editTransNo != null) {
        await _loadExisting(widget.editTransNo!);
      } else {
        if (widget.initialVoucherType != null) {
          _applyVoucherType(widget.initialVoucherType!);
        }
        setState(() => _loading = false);
      }
    } on DioException catch (e) {
      if (mounted) setState(() {
        _loading = false;
        _error   = 'Could not load data: ${e.response?.data ?? e.message}';
      });
    }
  }

  // ── Apply voucher type ─────────────────────────────────────────────────────

  void _applyVoucherType(String type) {
    for (final b in _bills) b.dispose();
    for (final l in _accountLines) l.dispose();
    setState(() {
      _voucherType   = type;
      _cashBankId    = null;
      _cashBankName  = null;
      _transCurrency = '';
      _rateCtrl.text = '1';
      _paymentMode   = isCashVoucher(type) ? 'CASH' : null;
      _partyId       = null;
      _partyName     = null;
      _partyCurrency = '';
      _partyRate     = 1.0;
      _bills         = [];
      _accountLines  = [_AccountLine()];
    });
  }

  // ── Load existing voucher ─────────────────────────────────────────────────

  Future<void> _loadExisting(String voucherNo) async {
    final session = ref.read(sessionProvider)!;
    try {
      final results = await Future.wait([
        DioClient.instance.get('/rih_finance_headers', queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'trans_no':   'eq.$voucherNo',
          'is_deleted': 'eq.false',
          'select':     '*',
          'limit':      '1',
        }),
        DioClient.instance.get('/rid_finance_lines', queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'trans_no':   'eq.$voucherNo',
          'is_deleted': 'eq.false',
          'select':     '*',
          'order':      'serial_no.asc',
        }),
      ]);

      final headers  = List<Map<String, dynamic>>.from(results[0].data as List);
      final lineRows = List<Map<String, dynamic>>.from(results[1].data as List);
      if (headers.isEmpty || !mounted) {
        setState(() => _loading = false);
        return;
      }

      final h   = headers.first;
      final vt  = h['voucher_type_code'] as String;
      final isOA = h['is_on_account'] as bool? ?? false;

      // Line 1 = cash / bank
      final line1         = lineRows.isNotEmpty ? lineRows.first : null;
      final transCurrency = line1?['trans_currency'] as String? ?? _baseCurrency;
      final cashBankId    = line1?['account_id']     as String?;
      final cashBankName  = cashBankId != null
          ? (_cashAccounts + _bankAccounts)
              .where((a) => a['id'] == cashBankId)
              .firstOrNull?['account_name'] as String?
          : null;
      final baseRate = (line1?['base_rate'] as num? ?? 1).toDouble();

      final restLines = lineRows.length > 1 ? lineRows.sublist(1) : <Map<String, dynamic>>[];

      // Common header restore
      void applyHeader() {
        _voucherType      = vt;
        _voucherNo        = voucherNo;
        _transDate        = DateTime.parse(h['trans_date'] as String);
        _isPosted         = h['is_posted']         as bool?   ?? false;
        _paymentMode      = h['payment_mode_code'] as String?;
        _refNoCtrl.text   = h['reference_no']      as String? ?? '';
        _chequeNoCtrl.text = h['cheque_no']        as String? ?? '';
        _remarksCtrl.text = h['remarks']            as String? ?? '';
        if (h['reference_date'] != null) {
          _refDate = DateTime.tryParse(h['reference_date'] as String);
        }
        if (h['cheque_date'] != null) {
          _chequeDate = DateTime.tryParse(h['cheque_date'] as String);
        }
        _cashBankId    = cashBankId;
        _cashBankName  = cashBankName;
        _transCurrency = transCurrency;
        _rateCtrl.text = _fmtRate(baseRate);
        _isOnAccount   = isOA;
        _loading       = false;
      }

      if (!isOA) {
        // Against Bill — restore party + bills
        final firstParty = restLines.isNotEmpty ? restLines.first : null;
        final partyId    = firstParty?['account_id']    as String?;
        final partyCurr  = firstParty?['party_currency'] as String? ?? _baseCurrency;
        final partyRate  = (firstParty?['party_rate']   as num? ?? 1).toDouble();
        final partyAcc   = partyId != null
            ? _partyAccounts.where((a) => a['id'] == partyId).firstOrNull
            : null;

        // Map bill no → saved trans amount for pre-filling
        final savedPaid = <String, double>{};
        for (final row in restLines) {
          final bn  = row['inv_bill_no']  as String?;
          final amt = (row['trans_amount'] as num? ?? 0).toDouble();
          if (bn != null && amt > 0) savedPaid[bn] = amt;
        }

        setState(() {
          applyHeader();
          _partyId       = partyId;
          _partyName     = partyAcc?['account_name'] as String?;
          _partyCurrency = partyCurr;
          _partyRate     = partyRate;
        });

        if (partyId != null) {
          await _loadPendingBills(savedPaid: savedPaid);
        }
      } else {
        // On Account — restore account lines
        for (final l in _accountLines) l.dispose();
        final loaded = restLines.map((row) {
          final accId = row['account_id'] as String?;
          final acc   = _otherAccounts.where((a) => a['id'] == accId).firstOrNull;
          return _AccountLine(
            accountId:   accId,
            accountName: acc?['account_name'] as String?,
            amount:      (row['trans_amount'] as num? ?? 0).toString(),
            remarks:     row['line_remarks']  as String? ?? '',
          );
        }).toList();

        setState(() {
          applyHeader();
          _accountLines = loaded.isNotEmpty ? loaded : [_AccountLine()];
        });
      }
    } on DioException catch (e) {
      if (mounted) setState(() {
        _loading = false;
        _error   = 'Could not load voucher: ${e.response?.data ?? e.message}';
      });
    }
  }

  // ── Cash / Bank account selected ──────────────────────────────────────────

  Future<void> _onCashBankSelected(Map<String, dynamic> account) async {
    final currency = _extractCurrency(account);
    setState(() {
      _cashBankId    = account['id']          as String;
      _cashBankName  = account['account_name'] as String;
      _transCurrency = currency;
      _rateCtrl.text = '1';
    });
    if (currency.isNotEmpty && currency != _baseCurrency) {
      await _fetchRate(currency, isParty: false);
    }
  }

  // ── Party selected ────────────────────────────────────────────────────────

  Future<void> _onPartySelected(Map<String, dynamic> account) async {
    final currency = _extractCurrency(account);
    for (final b in _bills) b.dispose();
    setState(() {
      _partyId       = account['id']          as String;
      _partyName     = account['account_name'] as String;
      _partyCurrency = currency;
      _partyRate     = 1.0;
      _bills         = [];
    });
    if (currency.isNotEmpty && currency != _baseCurrency) {
      await _fetchRate(currency, isParty: true);
    }
    await _loadPendingBills();
  }

  // ── Fetch exchange rate ───────────────────────────────────────────────────

  Future<void> _fetchRate(String toCurrency, {required bool isParty}) async {
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
      final rate = (res.data as num?)?.toDouble() ?? 1.0;
      if (!mounted) return;
      setState(() {
        if (isParty) {
          _partyRate = rate;
        } else {
          _rateCtrl.text = _fmtRate(rate);
        }
      });
    } on DioException { /* rate not found — keep default */ }
  }

  // ── Load pending bills ────────────────────────────────────────────────────

  Future<void> _loadPendingBills({Map<String, double>? savedPaid}) async {
    if (_partyId == null) return;
    final session = ref.read(sessionProvider)!;
    if (session.locationId == null) return;
    setState(() => _loadingBills = true);
    try {
      final res = await DioClient.instance.get('/v_pending_bills', queryParameters: {
        'company_id':  'eq.${session.companyId}',
        'location_id': 'eq.${session.locationId}',
        'account_id':  'eq.$_partyId',
        'select': 'trans_no,trans_date,inv_bill_no,inv_bill_date,'
                  'bill_amount,settled_amount,balance_amount,party_currency',
        'order': 'trans_date.asc',
      });
      final rows = List<Map<String, dynamic>>.from(res.data as List);
      for (final b in _bills) b.dispose();
      setState(() {
        _bills = rows.map((r) {
          final bn = r['inv_bill_no'] as String? ?? '';
          return _BillRow(
            transNo:       r['trans_no']        as String? ?? '',
            transDate:     r['trans_date']      as String? ?? '',
            invBillNo:     bn,
            invBillDate:   r['inv_bill_date']   as String?,
            billAmount:    (r['bill_amount']    as num? ?? 0).toDouble(),
            settledAmount: (r['settled_amount'] as num? ?? 0).toDouble(),
            balanceAmount: (r['balance_amount'] as num? ?? 0).toDouble(),
            partyCurrency: r['party_currency']  as String? ?? _partyCurrency,
            initialPay:    savedPaid?[bn] ?? 0,
          );
        }).toList();
        _loadingBills = false;
      });
    } catch (_) {
      setState(() => _loadingBills = false);
    }
  }

  // ── Computed totals ───────────────────────────────────────────────────────

  double get _totalTransAmount {
    if (!_isOnAccount) {
      return _bills.fold(0.0, (s, b) => s + b.payTrans);
    }
    return _accountLines.fold(0.0, (s, l) => s + l.amount);
  }

  // balance_party → balance in trans currency
  double _balanceTrans(double balanceParty) {
    if (_partyRate <= 0 || _rate <= 0) return balanceParty;
    return balanceParty * _rate / _partyRate;
  }

  // payTrans → pay in party currency
  double _payParty(double payTrans) {
    if (_rate <= 0) return payTrans;
    return payTrans * _partyRate / _rate;
  }

  // ── Save draft ────────────────────────────────────────────────────────────

  Future<bool> _saveDraft() async {
    final session = ref.read(sessionProvider)!;
    if (_voucherType == null) { _showSnack('Select a voucher type first.'); return false; }
    if (_cashBankId == null)  { _showSnack('Select a cash / bank account.'); return false; }
    if (!_isOnAccount && _partyId == null) {
      _showSnack('Select a customer or supplier for Against Bill mode.');
      return false;
    }
    if (_totalTransAmount <= 0) { _showSnack('Enter at least one payment amount.'); return false; }

    setState(() { _saving = true; _actionError = null; });
    try {
      final tc    = _transCurrency.isEmpty ? _baseCurrency : _transCurrency;
      final rate  = _rate;
      final n1    = line1Nature(_voucherType!);
      final n2    = counterNature(n1);
      final total = _totalTransAmount;

      final header = {
        'client_id':         session.clientId,
        'company_id':        session.companyId,
        'location_id':       session.locationId,
        'trans_no':          _voucherNo ?? '',
        'trans_date':        _fmtDate(_transDate),
        'voucher_type_code': _voucherType,
        'payment_mode_code': _paymentMode ?? '',
        'is_on_account':     _isOnAccount,
        'reference_no':      _refNoCtrl.text,
        'reference_date':    _refDate != null ? _fmtDate(_refDate!) : '',
        'cheque_no':         _chequeNoCtrl.text,
        'cheque_date':       _chequeDate != null ? _fmtDate(_chequeDate!) : '',
        'remarks':           _remarksCtrl.text,
      };

      final lines = <Map<String, dynamic>>[];

      // Line 1 — cash / bank
      lines.add({
        'serial_no':      1,
        'account_id':     _cashBankId,
        'trans_nature':   n1,
        'trans_amount':   total,
        'trans_currency': tc,
        'base_amount':    toBaseAmount(total, rate, tc, _baseCurrency),
        'base_rate':      rate,
        'local_amount':   toLocalAmount(total, rate, _localRate, tc, _localCurrency),
        'local_rate':     _localRate,
        'party_amount':   total,
        'party_currency': tc,
        'party_rate':     rate,
        'inv_bill_no':    '',
        'inv_bill_date':  '',
        'line_remarks':   '',
      });

      // Lines 2+ — bills or on-account
      var serial = 2;
      if (!_isOnAccount) {
        for (final bill in _bills) {
          if (bill.payTrans <= 0) continue;
          final payTrans = bill.payTrans;
          final payParty = _payParty(payTrans);
          lines.add({
            'serial_no':      serial++,
            'account_id':     _partyId,
            'trans_nature':   n2,
            'trans_amount':   payTrans,
            'trans_currency': tc,
            'base_amount':    toBaseAmount(payTrans, rate, tc, _baseCurrency),
            'base_rate':      rate,
            'local_amount':   toLocalAmount(payTrans, rate, _localRate, tc, _localCurrency),
            'local_rate':     _localRate,
            'party_amount':   payParty,
            'party_currency': _partyCurrency.isEmpty ? tc : _partyCurrency,
            'party_rate':     _partyRate,
            'inv_bill_no':    bill.invBillNo,
            'inv_bill_date':  bill.invBillDate ?? '',
            'line_remarks':   '',
          });
        }
      } else {
        for (final line in _accountLines) {
          if (line.accountId == null || line.amount <= 0) continue;
          lines.add({
            'serial_no':      serial++,
            'account_id':     line.accountId,
            'trans_nature':   n2,
            'trans_amount':   line.amount,
            'trans_currency': tc,
            'base_amount':    toBaseAmount(line.amount, rate, tc, _baseCurrency),
            'base_rate':      rate,
            'local_amount':   toLocalAmount(line.amount, rate, _localRate, tc, _localCurrency),
            'local_rate':     _localRate,
            'party_amount':   line.amount,
            'party_currency': tc,
            'party_rate':     rate,
            'inv_bill_no':    '',
            'inv_bill_date':  '',
            'line_remarks':   line.remarksCtrl.text,
          });
        }
      }

      if (lines.length < 2) {
        _showSnack('Add at least one payment line.');
        setState(() => _saving = false);
        return false;
      }

      final res = await DioClient.instance.post(
        '/rpc/fn_save_finance_voucher',
        data: {'p_header': header, 'p_lines': lines, 'p_user_id': session.userId},
      );
      if (mounted) {
        setState(() { _voucherNo = res.data as String?; _saving = false; });
        _showSnack('Draft saved — $_voucherNo', color: AppColors.positive);
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Post Voucher'),
        content: const Text(
            'Once posted this voucher is locked permanently. Continue?'),
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

    if (_voucherNo == null) {
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
        'p_trans_no':    _voucherNo,
        'p_trans_date':  _fmtDate(_transDate),
        'p_posted_by':   session.userId,
      });
      if (mounted) {
        setState(() { _isPosted = true; _posting = false; });
        _showSnack('$_voucherNo posted successfully.', color: AppColors.positive);
      }
    } on DioException catch (e) {
      if (mounted) setState(() {
        _posting     = false;
        _actionError = 'Post failed: ${e.response?.data ?? e.message}';
      });
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _extractCurrency(Map<String, dynamic> account) {
    final rel = account['rim_currencies'];
    if (rel is Map) return rel['currency_id'] as String? ?? _baseCurrency;
    return _baseCurrency;
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _displayDate(DateTime? d) {
    if (d == null) return 'Select date';
    const m = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day.toString().padLeft(2, '0')} ${m[d.month]} ${d.year}';
  }

  String _fmtRate(double r) {
    if (r >= 1000) return r.toStringAsFixed(2);
    if (r >= 1)    return r.toStringAsFixed(4);
    return r.toStringAsFixed(8);
  }

  String _fmtAmt(double a) => a.toStringAsFixed(2);

  void _showSnack(String msg, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: color));
  }

  Future<void> _pickDate(DateTime? current, ValueChanged<DateTime> onPicked) async {
    final d = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate:  DateTime(2099),
    );
    if (d != null) onPicked(d);
  }

  List<Map<String, dynamic>> get _cashBankList =>
      _voucherType == null ? [] :
      isCashVoucher(_voucherType!) ? _cashAccounts : _bankAccounts;

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final session   = ref.watch(sessionProvider);
    final isOffline = session?.offlineMode ?? false;
    final locked    = _isPosted || isOffline;

    String title;
    if (_voucherNo != null) {
      title = '${_typeLabels[_voucherType] ?? 'Voucher'}  ·  $_voucherNo';
    } else if (_voucherType != null) {
      title = 'New ${_typeLabels[_voucherType] ?? 'Voucher'}';
    } else {
      title = 'New Finance Voucher';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isOffline) const OfflineBanner(),

        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary)),
            const SizedBox(height: 2),
            if (_isPosted)
              _statusChip('POSTED — read only', AppColors.positive)
            else
              Text(
                _voucherNo != null ? 'Draft' : 'Unsaved draft',
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
          ]),
        ),

        const Divider(height: 20),

        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_error != null) ...[
                        _errorBanner(_error!),
                        const SizedBox(height: 16),
                      ],
                      _buildHeaderCard(locked),
                      const SizedBox(height: 20),
                      if (!_isOnAccount) _buildAgainstBillSection(locked),
                      if (_isOnAccount)  _buildOnAccountSection(locked),
                      const SizedBox(height: 12),
                      _buildTotalsBar(),
                      if (_actionError != null) ...[
                        const SizedBox(height: 12),
                        _errorBanner(_actionError!),
                      ],
                      if (!locked) ...[
                        const SizedBox(height: 20),
                        _buildActionButtons(),
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
    final isCash = _voucherType != null && isCashVoucher(_voucherType!);
    final showRateField = _transCurrency.isNotEmpty && _transCurrency != _baseCurrency;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [

          // Row 1: Voucher Type | Voucher No | Date
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              flex: 4,
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(
                    labelText: 'Voucher Type *',
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                value: _voucherType,
                isExpanded: true,
                items: _supportedTypes.map((t) => DropdownMenuItem(
                  value: t,
                  child: Text('$t — ${_typeLabels[t]}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13)),
                )).toList(),
                onChanged:
                    locked ? null : (v) { if (v != null) _applyVoucherType(v); },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: InputDecorator(
                decoration: const InputDecoration(
                    labelText: 'Voucher No',
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                child: Text(
                  _voucherNo ?? '(auto on save)',
                  style: TextStyle(
                      fontSize: 13,
                      color: _voucherNo != null
                          ? AppColors.textPrimary
                          : AppColors.textDisabled),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: InkWell(
                onTap: locked
                    ? null
                    : () => _pickDate(
                        _transDate, (d) => setState(() => _transDate = d)),
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: 'Date *',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    suffixIcon: Icon(Icons.calendar_today_outlined,
                        size: 15,
                        color: locked
                            ? AppColors.textDisabled
                            : AppColors.primary),
                  ),
                  child: Text(_displayDate(_transDate),
                      style: const TextStyle(fontSize: 13)),
                ),
              ),
            ),
          ]),

          const SizedBox(height: 12),

          // Row 2: Cash/Bank Account | Currency | Rate (1 base = X trans)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              flex: 5,
              child: DropdownButtonFormField<String>(
                decoration: InputDecoration(
                    labelText: isCash ? 'Cash Account *' : 'Bank Account *',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                value: _cashBankId,
                isExpanded: true,
                items: _cashBankList.map((a) => DropdownMenuItem(
                  value: a['id'] as String,
                  child: Text(a['account_name'] as String,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13)),
                )).toList(),
                onChanged: locked
                    ? null
                    : (v) {
                        if (v == null) return;
                        final acc =
                            _cashBankList.where((a) => a['id'] == v).firstOrNull;
                        if (acc != null) _onCashBankSelected(acc);
                      },
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 80,
              child: InputDecorator(
                decoration: const InputDecoration(
                    labelText: 'Currency',
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                child: Text(
                  _transCurrency.isEmpty ? '—' : _transCurrency,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: TextFormField(
                controller: _rateCtrl,
                enabled: !locked && showRateField,
                decoration: InputDecoration(
                  labelText: showRateField
                      ? '1 $_baseCurrency = '
                      : 'Rate',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  hintText: '1.0',
                ),
                style: const TextStyle(fontSize: 13),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))
                ],
                onChanged: (_) => setState(() {}),
              ),
            ),
          ]),

          const SizedBox(height: 12),

          // Row 3: Payment Mode | Ref No | Ref Date | Remarks
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              flex: 2,
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(
                    labelText: 'Payment Mode',
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                value: _paymentMode,
                isExpanded: true,
                items: _paymentModes.map((m) => DropdownMenuItem(
                  value: m['payment_mode_code'] as String,
                  child: Text(m['payment_mode_name'] as String,
                      style: const TextStyle(fontSize: 13)),
                )).toList(),
                // Lock to CASH for cash vouchers; editable for bank vouchers
                onChanged: (locked || isCash)
                    ? null
                    : (v) => setState(() => _paymentMode = v),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: TextFormField(
                controller: _refNoCtrl,
                enabled: !locked,
                decoration: const InputDecoration(
                    labelText: 'Ref No',
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                style: const TextStyle(fontSize: 13),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: InkWell(
                onTap: locked
                    ? null
                    : () => _pickDate(
                        _refDate, (d) => setState(() => _refDate = d)),
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: 'Ref Date',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    suffixIcon: Icon(Icons.calendar_today_outlined,
                        size: 15,
                        color: locked
                            ? AppColors.textDisabled
                            : AppColors.primary),
                  ),
                  child: Text(
                    _displayDate(_refDate),
                    style: TextStyle(
                        fontSize: 13,
                        color: _refDate != null
                            ? AppColors.textPrimary
                            : AppColors.textDisabled),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: TextFormField(
                controller: _remarksCtrl,
                enabled: !locked,
                decoration: const InputDecoration(
                    labelText: 'Remarks',
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ]),

          // Cheque row — only for CHEQUE payment mode
          if (_paymentMode == 'CHEQUE') ...[
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: TextFormField(
                  controller: _chequeNoCtrl,
                  enabled: !locked,
                  decoration: const InputDecoration(
                      labelText: 'Cheque No',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: InkWell(
                  onTap: locked
                      ? null
                      : () => _pickDate(
                          _chequeDate ?? _transDate,
                          (d) => setState(() => _chequeDate = d)),
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Cheque Date',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      suffixIcon: Icon(Icons.calendar_today_outlined,
                          size: 15,
                          color: locked
                              ? AppColors.textDisabled
                              : AppColors.primary),
                    ),
                    child: Text(
                      _displayDate(_chequeDate),
                      style: TextStyle(
                          fontSize: 13,
                          color: _chequeDate != null
                              ? AppColors.textPrimary
                              : AppColors.textDisabled),
                    ),
                  ),
                ),
              ),
            ]),
          ],

          const SizedBox(height: 12),

          // Row 4: Against Bill | On Account toggle
          Row(children: [
            Radio<bool>(
              value: false,
              groupValue: _isOnAccount,
              onChanged: locked ? null : (_) => setState(() => _isOnAccount = false),
            ),
            const Text('Against Bill', style: TextStyle(fontSize: 13)),
            const SizedBox(width: 20),
            Radio<bool>(
              value: true,
              groupValue: _isOnAccount,
              onChanged: locked ? null : (_) => setState(() => _isOnAccount = true),
            ),
            const Text('On Account', style: TextStyle(fontSize: 13)),
          ]),
        ]),
      ),
    );
  }

  // ── Against Bill section ──────────────────────────────────────────────────

  Widget _buildAgainstBillSection(bool locked) {
    final transCurr = _transCurrency.isEmpty ? _baseCurrency : _transCurrency;
    final partyCurr = _partyCurrency.isEmpty ? transCurr : _partyCurrency;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          decoration: const InputDecoration(
              labelText: 'Customer / Supplier *',
              border: OutlineInputBorder(),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
          value: _partyId,
          isExpanded: true,
          items: _partyAccounts.map((a) => DropdownMenuItem(
            value: a['id'] as String,
            child: Text(a['account_name'] as String,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13)),
          )).toList(),
          onChanged: locked
              ? null
              : (v) {
                  if (v == null) return;
                  final acc =
                      _partyAccounts.where((a) => a['id'] == v).firstOrNull;
                  if (acc != null) _onPartySelected(acc);
                },
        ),

        if (_partyCurrency.isNotEmpty && _partyCurrency != transCurr) ...[
          const SizedBox(height: 6),
          Text(
            'Party currency: $_partyCurrency  ·  '
            'Rate: 1 $_baseCurrency = ${_fmtRate(_partyRate)} $_partyCurrency',
            style: const TextStyle(
                fontSize: 11, color: AppColors.textSecondary),
          ),
        ],

        const SizedBox(height: 16),

        if (_partyId == null)
          const Text(
            'Select a customer or supplier to see pending bills.',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          )
        else if (_loadingBills)
          const Center(
              child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator()))
        else if (_bills.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: const Text('No pending bills found for this party.',
                style: TextStyle(
                    fontSize: 13, color: AppColors.textSecondary)),
          )
        else ...[
          const Text('Pending Bills',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary)),
          const SizedBox(height: 8),
          _buildBillsTable(locked, transCurr, partyCurr),
        ],
      ],
    );
  }

  Widget _buildBillsTable(bool locked, String transCurr, String partyCurr) {
    const w1 = 130.0; // Bill No
    const w2 = 95.0;  // Bill Date
    const w3 = 110.0; // Bill Amt (party)
    const w4 = 100.0; // Paid (party)
    const w5 = 100.0; // Balance (party)
    const w6 = 105.0; // Balance (trans)
    const w7 = 125.0; // Pay (trans) — editable
    const w8 = 110.0; // Pay (party) — calculated

    Widget hdr(String label, double w) => SizedBox(
      width: w,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Text(label,
            textAlign: TextAlign.right,
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.white)),
      ),
    );

    Widget hdrLeft(String label, double w) => SizedBox(
      width: w,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Text(label,
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.white)),
      ),
    );

    Widget cell(String value, double w, {Color? color}) => SizedBox(
      width: w,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Text(value,
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 12,
                color: color ?? AppColors.textPrimary)),
      ),
    );

    Widget cellLeft(String value, double w) => SizedBox(
      width: w,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Text(value,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12)),
      ),
    );

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Container(
            decoration: const BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
            ),
            child: Row(children: [
              hdrLeft('Bill No', w1),
              hdrLeft('Bill Date', w2),
              hdr('Bill Amt\n($partyCurr)', w3),
              hdr('Paid\n($partyCurr)', w4),
              hdr('Balance\n($partyCurr)', w5),
              hdr('Balance\n($transCurr)', w6),
              hdr('Pay\n($transCurr)', w7),
              hdr('Pay\n($partyCurr)', w8),
            ]),
          ),

          // Data rows
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.border),
              borderRadius:
                  const BorderRadius.vertical(bottom: Radius.circular(6)),
            ),
            child: Column(
              children: _bills.asMap().entries.map((e) {
                final i    = e.key;
                final bill = e.value;
                final balTrans = _balanceTrans(bill.balanceAmount);
                final payParty = _payParty(bill.payTrans);
                final dateStr  = bill.transDate.length >= 10
                    ? bill.transDate.substring(0, 10)
                    : bill.transDate;

                return Container(
                  color: i.isOdd ? Colors.grey.shade50 : Colors.white,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      cellLeft(bill.invBillNo, w1),
                      cellLeft(dateStr, w2),
                      cell(_fmtAmt(bill.billAmount), w3),
                      cell(_fmtAmt(bill.settledAmount), w4),
                      cell(_fmtAmt(bill.balanceAmount), w5,
                          color: AppColors.negative),
                      cell(_fmtAmt(balTrans), w6),
                      // Pay (trans) — editable
                      SizedBox(
                        width: w7,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 4),
                          child: TextFormField(
                            controller: bill.payTransCtrl,
                            enabled: !locked,
                            textAlign: TextAlign.right,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 6),
                            ),
                            style: const TextStyle(fontSize: 12),
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                  RegExp(r'[\d.]'))
                            ],
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                      ),
                      cell(_fmtAmt(payParty), w8,
                          color: AppColors.positive),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  // ── On Account section ────────────────────────────────────────────────────

  Widget _buildOnAccountSection(bool locked) {
    final n2   = _voucherType != null
        ? counterNature(line1Nature(_voucherType!))
        : '—';
    final verb = n2 == 'DR' ? 'Debit' : 'Credit';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Text('$verb Accounts',
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary)),
          const Spacer(),
          if (!locked)
            TextButton.icon(
              onPressed: () =>
                  setState(() => _accountLines.add(_AccountLine())),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add Line',
                  style: TextStyle(fontSize: 13)),
            ),
        ]),
        const SizedBox(height: 8),

        ..._accountLines.asMap().entries.map((e) {
          final i    = e.key;
          final line = e.value;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Expanded(
                flex: 4,
                child: DropdownButtonFormField<String>(
                  decoration: const InputDecoration(
                      labelText: 'Account',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                  value: line.accountId,
                  isExpanded: true,
                  items: _otherAccounts.map((a) {
                    final id = a['id'] as String;
                    // Disable accounts already used in another line
                    final used = _accountLines
                        .where((l) => l != line && l.accountId == id)
                        .isNotEmpty;
                    return DropdownMenuItem(
                      value: id,
                      enabled: !used,
                      child: Text(a['account_name'] as String,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13,
                              color: used
                                  ? AppColors.textDisabled
                                  : null)),
                    );
                  }).toList(),
                  onChanged: locked
                      ? null
                      : (v) {
                          if (v == null) return;
                          final acc = _otherAccounts
                              .where((a) => a['id'] == v)
                              .firstOrNull;
                          setState(() {
                            line.accountId   = v;
                            line.accountName = acc?['account_name'] as String?;
                          });
                        },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: TextFormField(
                  controller: line.amountCtrl,
                  enabled: !locked,
                  textAlign: TextAlign.right,
                  decoration: const InputDecoration(
                      labelText: 'Amount',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                  style: const TextStyle(fontSize: 13),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))
                  ],
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child: TextFormField(
                  controller: line.remarksCtrl,
                  enabled: !locked,
                  decoration: const InputDecoration(
                      labelText: 'Remarks',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              if (!locked && _accountLines.length > 1) ...[
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () {
                    final removed = _accountLines.removeAt(i);
                    removed.dispose();
                    setState(() {});
                  },
                  icon: const Icon(Icons.remove_circle_outline,
                      size: 18, color: AppColors.negative),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ]),
          );
        }),
      ],
    );
  }

  // ── Totals bar ────────────────────────────────────────────────────────────

  Widget _buildTotalsBar() {
    final total     = _totalTransAmount;
    final curr      = _transCurrency.isEmpty ? _baseCurrency : _transCurrency;
    final partyCurr = _partyCurrency.isEmpty ? curr : _partyCurrency;
    final hasAmount = total > 0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: hasAmount
            ? AppColors.positive.withOpacity(0.06)
            : Colors.grey.shade50,
        border: Border.all(
          color: hasAmount
              ? AppColors.positive.withOpacity(0.3)
              : AppColors.border,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        const Text('Total: ',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
        Text('${_fmtAmt(total)} $curr',
            style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppColors.primary)),
        // In Against Bill mode show party total when party currency differs
        if (!_isOnAccount &&
            partyCurr.isNotEmpty &&
            partyCurr != curr &&
            total > 0) ...[
          const SizedBox(width: 8),
          Text('= ${_fmtAmt(_payParty(total))} $partyCurr',
              style: const TextStyle(
                  fontSize: 13, color: AppColors.textSecondary)),
        ],
        const Spacer(),
        if (hasAmount) ...[
          const Icon(Icons.check_circle_outline,
              size: 16, color: AppColors.positive),
          const SizedBox(width: 4),
          const Text('Balanced',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.positive)),
        ] else
          const Text('Enter amounts',
              style: TextStyle(
                  fontSize: 13, color: AppColors.textSecondary)),
      ]),
    );
  }

  // ── Action buttons ────────────────────────────────────────────────────────

  Widget _buildActionButtons() {
    return Row(children: [
      OutlinedButton.icon(
        onPressed: (_saving || _posting) ? null : _saveDraft,
        icon: _saving
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.save_outlined, size: 16),
        label: Text(_saving ? 'Saving…' : 'Save Draft'),
        style: OutlinedButton.styleFrom(
            minimumSize: const Size(140, 44)),
      ),
      const SizedBox(width: 12),
      FilledButton.icon(
        onPressed: (_saving || _posting) ? null : _postVoucher,
        icon: _posting
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.check_circle_outline, size: 16),
        label: Text(_posting ? 'Posting…' : 'Post Voucher'),
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.secondary,
          minimumSize: const Size(140, 44),
        ),
      ),
    ]);
  }

  // ── Utility widgets ───────────────────────────────────────────────────────

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
      Expanded(
          child: Text(msg,
              style: const TextStyle(
                  color: AppColors.negative, fontSize: 13))),
    ]),
  );

  Widget _statusChip(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: color.withOpacity(0.1),
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: color.withOpacity(0.4)),
    ),
    child: Text(label,
        style: TextStyle(
            fontSize: 11,
            color: color,
            fontWeight: FontWeight.w600)),
  );
}
