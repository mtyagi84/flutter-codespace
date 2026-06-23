import 'dart:async';
import 'dart:math';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../data/models/finance_voucher_model.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/voucher_logic.dart';
import '../../../../core/models/menu_models.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../providers/finance_voucher_providers.dart';

MenuFeature? _findFeature(List<MenuModule> modules, String screenPath) {
  for (final mod in modules) {
    for (final grp in mod.groups) {
      for (final feat in grp.features) {
        if (feat.screenName == screenPath) return feat;
      }
    }
  }
  return null;
}

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
  String  accountCurrency; // ledger currency of this account
  double  partyRate;       // fn_get_rate(trans → accountCurrency)
  final TextEditingController amountCtrl;
  final TextEditingController remarksCtrl;

  _AccountLine({
    this.accountId,
    this.accountName,
    this.accountCurrency = '',
    this.partyRate       = 1.0,
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
  String    _partyNature   = '';   // 'Customer' or 'Supplier'
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
    setState(() { _loading = true; _error = null; });
    final session = ref.read(sessionProvider)!;
    try {
      List<Map<String, dynamic>> accounts;
      List<Map<String, dynamic>> modes;
      String base;
      String local;

      if (session.offlineMode) {
        // Serve accounts from local Drift cache; payment modes and currencies
        // are pre-synced during online login via SyncScreen.
        final db   = ref.read(appDatabaseProvider);
        final rows = await (db.select(db.accountsCache)
              ..where((t) => t.clientId.equals(session.clientId))
              ..where((t) => t.companyId.equals(session.companyId))
              ..where((t) => t.isActive.equals(true)))
            .get();
        accounts = rows.map((r) => {
          'id':             r.id,
          'account_code':   r.accountCode,
          'account_name':   r.accountName,
          'account_nature': r.accountNature,
          'parent':         {'account_name': r.parentName},
          'rim_currencies': {'currency_id':  r.accountCurrency},
        }).toList();
        // Offline: base/local currency cached in session (set during sync login).
        // Payment modes are not needed offline (vouchers stay PENDING).
        modes = [];
        base  = '';
        local = '';
      } else {
        final futures = await Future.wait<dynamic>([
          ref.read(accountsProvider.future),
          ref.read(paymentModesProvider.future),
          ref.read(baseCurrencyProvider.future),
          ref.read(localCurrencyProvider.future),
        ]);
        accounts = futures[0] as List<Map<String, dynamic>>;
        modes    = futures[1] as List<Map<String, dynamic>>;
        base     = futures[2] as String;
        local    = futures[3] as String;

        // Populate AccountsCache so the data is available on next offline login.
        unawaited(_cacheAccountsLocally(accounts, session));
      }

      if (!mounted) return;

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
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error   = 'Could not load data: $e';
        });
      }
    }
  }

  Future<void> _cacheAccountsLocally(
    List<Map<String, dynamic>> accounts,
    UserSession session,
  ) async {
    final db  = ref.read(appDatabaseProvider);
    final now = DateTime.now();
    for (final a in accounts) {
      final parentRel = a['parent'];
      final currRel   = a['rim_currencies'];
      await db.into(db.accountsCache).insertOnConflictUpdate(AccountsCacheCompanion.insert(
        id:              a['id'] as String,
        clientId:        session.clientId,
        companyId:       session.companyId,
        accountCode:     a['account_code']   as String? ?? '',
        accountName:     a['account_name']   as String? ?? '',
        accountNature:   a['account_nature'] as String? ?? '',
        parentName:      Value(parentRel is Map
            ? (parentRel['account_name'] as String? ?? '') : ''),
        accountCurrency: Value(currRel is Map
            ? (currRel['currency_id'] as String? ?? '') : ''),
        cachedAt:        Value(now),
      ));
    }
  }

  // ── Apply voucher type ─────────────────────────────────────────────────────

  void _applyVoucherType(String type) {
    for (final b in _bills) b.dispose();
    for (final l in _accountLines) l.dispose();
    setState(() {
      _voucherType   = type;
      _cashBankId    = null;
      _transCurrency = '';
      _rateCtrl.text = '1';
      _localRate     = 1.0;
      _paymentMode   = isCashVoucher(type) ? 'CASH' : null;
      _isOnAccount   = false;
      _partyId       = null;
      _partyName     = null;
      _partyNature   = '';
      _partyCurrency = '';
      _partyRate     = 1.0;
      _bills         = [];
      _accountLines  = [_AccountLine()];
    });
  }

  // ── Load existing voucher ─────────────────────────────────────────────────

  Future<void> _loadExisting(String voucherNo) async {
    final session  = ref.read(sessionProvider)!;
    final repo     = ref.read(financeVoucherRepositoryProvider);
    try {
      // Sequential: get header first to obtain trans_date, then fetch lines
      // by the composite key (trans_no, trans_date) — trans_no alone is not
      // unique after period resets (migration 021).
      final header = await repo.getHeader(
        clientId:  session.clientId,
        companyId: session.companyId,
        transNo:   voucherNo,
      );
      if (header == null || !mounted) {
        setState(() => _loading = false);
        return;
      }
      final lineObjs = await repo.getLines(
        clientId:  session.clientId,
        companyId: session.companyId,
        transNo:   voucherNo,
        transDate: header.transDate,
      );

      final vt   = header.voucherTypeCode;
      final isOA = header.isOnAccount;

      // Line 1 = cash / bank entry
      final line1           = lineObjs.isNotEmpty ? lineObjs.first : null;
      final transCurrency   = line1?.transCurrency ?? _baseCurrency;
      final cashBankId      = line1?.accountId.isEmpty == true ? null : line1?.accountId;
      final storedBaseRate  = line1?.baseRate ?? 1.0;
      final restoredLocalRate = line1?.localRate ?? 1.0;
      // Display rate "1 base = X trans" = 1 / storedBaseRate (when trans ≠ base)
      final displayRate = (storedBaseRate > 0 && transCurrency != _baseCurrency)
          ? 1.0 / storedBaseRate
          : 1.0;

      final restObjs = lineObjs.length > 1 ? lineObjs.sublist(1) : <FinanceVoucherLine>[];

      void applyHeader() {
        _voucherType       = vt;
        _voucherNo         = voucherNo;
        _transDate         = DateTime.parse(header.transDate);
        _isPosted          = header.isPosted;
        _paymentMode       = header.paymentModeCode.isEmpty ? null : header.paymentModeCode;
        _refNoCtrl.text    = header.referenceNo;
        _chequeNoCtrl.text = header.chequeNo;
        _remarksCtrl.text  = header.remarks;
        if (header.referenceDate.isNotEmpty) {
          _refDate = DateTime.tryParse(header.referenceDate);
        }
        if (header.chequeDate.isNotEmpty) {
          _chequeDate = DateTime.tryParse(header.chequeDate);
        }
        _cashBankId    = cashBankId;
        _transCurrency = transCurrency;
        _rateCtrl.text = _fmtRate(displayRate);
        _localRate     = restoredLocalRate;
        _isOnAccount   = isOA;
        _loading       = false;
      }

      if (!isOA) {
        // Against Bill — restore party + bills
        final firstParty = restObjs.isNotEmpty ? restObjs.first : null;
        final partyId    = firstParty?.accountId.isEmpty == true ? null : firstParty?.accountId;
        final partyCurr  = firstParty?.partyCurrency ?? _baseCurrency;
        final partyRate  = firstParty?.partyRate ?? 1.0;
        final partyAcc   = partyId != null
            ? _partyAccounts.where((a) => a['id'] == partyId).firstOrNull
            : null;

        final savedPaid = <String, double>{};
        for (final row in restObjs) {
          if (row.invBillNo.isNotEmpty && row.transAmount > 0) {
            savedPaid[row.invBillNo] = row.transAmount;
          }
        }

        setState(() {
          applyHeader();
          _partyId       = partyId;
          _partyName     = partyAcc?['account_name'] as String?;
          _partyNature   = partyAcc?['account_nature'] as String? ?? '';
          _partyCurrency = partyCurr;
          _partyRate     = partyRate;
        });

        if (partyId != null) {
          await _loadPendingBills(savedPaid: savedPaid);
        }
      } else {
        // On Account — restore account lines
        for (final l in _accountLines) l.dispose();
        final loaded = restObjs.map((row) {
          final accId = row.accountId.isEmpty ? null : row.accountId;
          final acc   = _otherAccounts.where((a) => a['id'] == accId).firstOrNull;
          return _AccountLine(
            accountId:       accId,
            accountName:     acc?['account_name'] as String?,
            accountCurrency: acc != null ? _extractCurrency(acc) : '',
            partyRate:       row.partyRate,
            amount:          row.transAmount.toString(),
            remarks:         row.lineRemarks,
          );
        }).toList();

        setState(() {
          applyHeader();
          _accountLines = loaded.isNotEmpty ? loaded : [_AccountLine()];
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error   = 'Could not load voucher: $e';
        });
      }
    }
  }

  // ── Copy voucher ─────────────────────────────────────────────────────────

  void _applyCopy() {
    setState(() {
      _voucherNo    = null;           // becomes a new unsaved draft
      _transDate    = DateTime.now(); // default to today
      _isPosted     = false;
      _refNoCtrl.clear();
      _refDate      = null;
      _chequeNoCtrl.clear();
      _chequeDate   = null;
      // _accountLines, cash/bank, type, currency, rate, remarks: kept as-is
    });
    _showSnack('Copied — edit as needed and save as a new draft.',
        color: AppColors.secondary);
  }

  // ── Cash / Bank account selected ──────────────────────────────────────────

  Future<void> _onCashBankSelected(Map<String, dynamic> account) async {
    final currency = _extractCurrency(account);
    setState(() {
      _cashBankId    = account['id'] as String;
      _transCurrency = currency;
      _rateCtrl.text = '1';
      _localRate     = 1.0;
    });
    await _fetchRatesForTrans(currency);
  }

  // ── Party selected ────────────────────────────────────────────────────────

  Future<void> _onPartySelected(Map<String, dynamic> account) async {
    final currency = _extractCurrency(account);
    final nature   = account['account_nature'] as String? ?? '';
    final billOk   = _voucherType == null || canSettleAgainstBill(_voucherType!, nature);
    for (final b in _bills) b.dispose();
    setState(() {
      _partyId       = account['id']           as String;
      _partyName     = account['account_name'] as String;
      _partyNature   = nature;
      _partyCurrency = currency;
      _partyRate     = 1.0;
      _bills         = [];
      // Force On Account when this party type cannot be settled against a bill.
      if (!billOk) _isOnAccount = true;
    });
    final trans = _transCurrency.isEmpty ? _baseCurrency : _transCurrency;
    final rate = await _fetchCrossRate(trans, currency);
    if (mounted && rate != null) setState(() => _partyRate = rate);
    // Only load pending bills when Against Bill mode is active.
    if (!_isOnAccount) await _loadPendingBills();
  }

  // ── Exchange rate helpers ─────────────────────────────────────────────────

  // Calls fn_get_exchange_rate(from → to) — handles same, reverse, cross.
  Future<double?> _fetchCrossRate(String from, String to) async {
    if (from.isEmpty || to.isEmpty || from == to) return 1.0;
    final session = ref.read(sessionProvider)!;
    if (session.locationId == null) return null;
    try {
      return await ref.read(financeVoucherRepositoryProvider).fetchExchangeRate(
        companyId:    session.companyId,
        locationId:   session.locationId!,
        fromCurrency: from,
        toCurrency:   to,
        rateDate:     _fmtDate(_transDate),
      );
    } catch (_) { return null; }
  }

  // Fetches the display rate ("1 base = X trans") and the local rate
  // whenever the transaction currency changes.
  Future<void> _fetchRatesForTrans(String transCurrency) async {
    if (transCurrency.isEmpty) return;
    // Display rate: "1 base = X trans" — only show / fetch when trans ≠ base
    if (transCurrency != _baseCurrency && _baseCurrency.isNotEmpty) {
      final dr = await _fetchCrossRate(_baseCurrency, transCurrency);
      if (mounted && dr != null) setState(() => _rateCtrl.text = _fmtRate(dr));
    }
    // Local rate: fn_get_rate(trans → local) — always fetch
    if (_localCurrency.isNotEmpty) {
      final lr = await _fetchCrossRate(transCurrency, _localCurrency);
      if (mounted && lr != null) setState(() => _localRate = lr);
    }
  }

  // ── Load pending bills ────────────────────────────────────────────────────

  Future<void> _loadPendingBills({Map<String, double>? savedPaid}) async {
    if (_partyId == null) return;
    final session = ref.read(sessionProvider)!;
    if (session.locationId == null) return;
    setState(() => _loadingBills = true);
    try {
      final rows = await ref.read(financeVoucherRepositoryProvider).getPendingBills(
        companyId:  session.companyId,
        locationId: session.locationId!,
        accountId:  _partyId!,
      );
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

  // balance in party currency → balance in trans currency
  // partyRate = fn_get_rate(trans → party), so trans = party / partyRate
  double _balanceTrans(double balanceParty) {
    if (_partyRate <= 0) return balanceParty;
    return balanceParty / _partyRate;
  }

  // trans amount → party currency amount
  // party_amount = trans_amount × partyRate
  double _payParty(double payTrans) => payTrans * _partyRate;

  // ── Save draft ────────────────────────────────────────────────────────────

  Future<bool> _saveDraft() async {
    final session  = ref.read(sessionProvider)!;
    final isOffline = session.offlineMode;
    if (_voucherType == null) { _showSnack('Select a voucher type first.'); return false; }
    if (_cashBankId == null)  { _showSnack('Select a cash / bank account.'); return false; }
    if (!_isOnAccount && _partyId == null) {
      _showSnack('Select a customer or supplier for Against Bill mode.');
      return false;
    }
    if (_paymentMode == 'CHEQUE' && _chequeNoCtrl.text.trim().isEmpty) {
      _showSnack('Enter a cheque number for Cheque payment mode.');
      return false;
    }
    if (_totalTransAmount <= 0) { _showSnack('Enter at least one payment amount.'); return false; }

    setState(() { _saving = true; _actionError = null; });
    try {
      final tc        = _transCurrency.isEmpty ? _baseCurrency : _transCurrency;
      final displayRate = _rate; // "1 base = X trans" (UI display value)
      // base_rate = fn_get_rate(trans → base) = 1/displayRate; always multiply formula
      final baseRate  = (tc == _baseCurrency || displayRate <= 0) ? 1.0 : 1.0 / displayRate;
      final n1        = line1Nature(_voucherType!);
      final n2        = counterNature(n1);
      final total     = _totalTransAmount;

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

      // Line 1 — cash / bank (always in trans_currency, so party = trans)
      lines.add({
        'serial_no':      1,
        'account_id':     _cashBankId,
        'trans_nature':   n1,
        'trans_amount':   total,
        'trans_currency': tc,
        'base_amount':    toBaseAmount(total, baseRate),
        'base_rate':      baseRate,
        'local_amount':   toLocalAmount(total, _localRate),
        'local_rate':     _localRate,
        'party_amount':   total,
        'party_currency': tc,
        'party_rate':     1.0,
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
          lines.add({
            'serial_no':      serial++,
            'account_id':     _partyId,
            'trans_nature':   n2,
            'trans_amount':   payTrans,
            'trans_currency': tc,
            'base_amount':    toBaseAmount(payTrans, baseRate),
            'base_rate':      baseRate,
            'local_amount':   toLocalAmount(payTrans, _localRate),
            'local_rate':     _localRate,
            'party_amount':   _payParty(payTrans),  // trans × partyRate
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
          final lineCurr = line.accountCurrency.isEmpty ? _baseCurrency : line.accountCurrency;
          lines.add({
            'serial_no':      serial++,
            'account_id':     line.accountId,
            'trans_nature':   n2,
            'trans_amount':   line.amount,
            'trans_currency': tc,
            'base_amount':    toBaseAmount(line.amount, baseRate),
            'base_rate':      baseRate,
            'local_amount':   toLocalAmount(line.amount, _localRate),
            'local_rate':     _localRate,
            'party_amount':   line.amount * line.partyRate,
            'party_currency': lineCurr,
            'party_rate':     line.partyRate,
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

      if (isOffline) {
        // Offline: enqueue for later sync; use a local UUID as document ID.
        final localId = _generateLocalId();
        await ref.read(syncEngineProvider).enqueue(
          documentType: 'FINANCE_VOUCHER',
          documentId:   localId,
          endpoint:     '/rpc/fn_save_finance_voucher',
          payload:      {'p_header': header, 'p_lines': lines, 'p_user_id': session.userId},
        );
        // Cache locally so the voucher is readable in the entry screen while still offline.
        await ref.read(financeVoucherRepositoryProvider).cacheVoucherLocally(
          effectiveTransNo: localId,
          header: header,
          lines:  lines,
        );
        if (mounted) {
          setState(() { _voucherNo = localId; _saving = false; });
          _showSnack('Saved offline — will sync when online.',
              color: AppColors.secondary);
          return true;
        }
      } else {
        final transNo = await ref.read(financeVoucherRepositoryProvider).save(
          header: header,
          lines:  lines,
          userId: session.userId,
        );
        // Cache for offline access in subsequent sessions.
        unawaited(ref.read(financeVoucherRepositoryProvider).cacheVoucherLocally(
          effectiveTransNo: transNo,
          header: header,
          lines:  lines,
        ));
        if (mounted) {
          setState(() { _voucherNo = transNo; _saving = false; });
          _showSnack('Draft saved — $transNo', color: AppColors.positive);
          return true;
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving      = false;
          _actionError = 'Save failed: $e';
        });
      }
    }
    return false;
  }

  String _generateLocalId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rng   = Random.secure();
    final ts    = DateTime.now().millisecondsSinceEpoch.toString();
    final rand  = List.generate(6, (_) => chars[rng.nextInt(chars.length)]).join();
    return 'LOCAL-$ts-$rand';
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
      await ref.read(financeVoucherRepositoryProvider).post(
        clientId:   session.clientId,
        companyId:  session.companyId,
        locationId: session.locationId ?? '',
        transNo:    _voucherNo!,
        transDate:  _fmtDate(_transDate),
        postedBy:   session.userId,
      );
      if (mounted) {
        setState(() { _isPosted = true; _posting = false; });
        _showSnack('$_voucherNo posted successfully.', color: AppColors.positive);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _posting     = false;
          _actionError = 'Post failed: $e';
        });
      }
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _extractCurrency(Map<String, dynamic> account) {
    final rel = account['rim_currencies'];
    if (rel is Map) return rel['currency_id'] as String? ?? _baseCurrency;
    return _baseCurrency;
  }

  String _extractParentName(Map<String, dynamic> account) {
    final rel = account['parent'];
    if (rel is Map) return rel['account_name'] as String? ?? '';
    return '';
  }

  String _displayAccount(Map<String, dynamic> a) =>
      '[${a['account_code']}] ${a['account_name']}';

  String _findAccountDisplay(List<Map<String, dynamic>> list, String id) {
    final acc = list.where((a) => a['id'] == id).firstOrNull;
    return acc != null ? _displayAccount(acc) : '';
  }

  Widget _buildAccountSearch({
    required List<Map<String, dynamic>> accounts,
    required String? selectedId,
    required bool locked,
    required InputDecoration decoration,
    required void Function(Map<String, dynamic>) onSelected,
    required VoidCallback onCleared,
    double height = 56.0,
    String? keyValue,
  }) {
    return SizedBox(
      height: height,
      child: Autocomplete<Map<String, dynamic>>(
        key: ValueKey(keyValue ?? selectedId ?? 'none'),
        initialValue: TextEditingValue(
          text: selectedId != null
              ? _findAccountDisplay(accounts, selectedId)
              : '',
        ),
        optionsBuilder: (textEditingValue) {
          final q = textEditingValue.text.toLowerCase().trim();
          final filtered = q.isEmpty
              ? accounts
              : accounts.where((a) =>
                  (a['account_code'] as String? ?? '').toLowerCase().contains(q) ||
                  (a['account_name']  as String? ?? '').toLowerCase().contains(q));
          return filtered.take(50);
        },
        displayStringForOption: _displayAccount,
        fieldViewBuilder: (context, textCtrl, focusNode, onFieldSubmitted) =>
            TextFormField(
              controller: textCtrl,
              focusNode: focusNode,
              enabled: !locked,
              onChanged: (v) { if (v.isEmpty) onCleared(); },
              decoration: decoration,
              style: const TextStyle(fontSize: 13),
            ),
        optionsViewBuilder: (context, onSel, options) => Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(4),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, idx) {
                  final a          = options.elementAt(idx);
                  final parentName = _extractParentName(a);
                  return InkWell(
                    onTap: () => onSel(a),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_displayAccount(a),
                              style: const TextStyle(fontSize: 13)),
                          if (parentName.isNotEmpty)
                            Text(parentName,
                                style: const TextStyle(
                                    fontSize: 11,
                                    color: AppColors.textSecondary)),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        onSelected: (a) { if (!locked) onSelected(a); },
      ),
    );
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

  // Whether "Against Bill" mode is valid for the current voucher type + party type.
  bool get _canAgainstBill =>
      _voucherType == null || canSettleAgainstBill(_voucherType!, _partyNature);

  // Party accounts eligible for Against Bill for the current voucher type.
  // Receipt → Customers only; Payment → Suppliers only.
  List<Map<String, dynamic>> get _eligiblePartyAccounts {
    if (_voucherType == null) return _partyAccounts;
    final wantNature = isReceiptVoucher(_voucherType!) ? 'Customer' : 'Supplier';
    return _partyAccounts
        .where((a) => (a['account_nature'] as String?) == wantNature)
        .toList();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final session   = ref.watch(sessionProvider);
    final isOffline = session?.offlineMode ?? false;
    final isMobile  = Responsive.isMobile(context);
    final menus     = ref.watch(menuProvider);
    final feature   = _findFeature(menus, RouteNames.paymentReceipt);

    if (feature == null) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline, size: 48, color: Color(0xFFADB5BD)),
            SizedBox(height: 12),
            Text('You do not have access to this screen.',
                style: TextStyle(color: Color(0xFF6B7280))),
          ],
        ),
      );
    }

    final canSave    = !_isPosted &&
        (_voucherNo == null ? feature.addAllowed : feature.editAllowed);
    final canApprove = !_isPosted && !isOffline && feature.approveAllowed;
    final locked     = !canSave;

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
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
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
              if (_voucherNo != null && _isOnAccount)
                Tooltip(
                  message: 'Copy to new voucher',
                  child: IconButton(
                    icon: const Icon(Icons.copy_outlined),
                    color: AppColors.primary,
                    onPressed: _applyCopy,
                  ),
                ),
            ],
          ),
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
                        _errorBanner(_error!, onRetry: _init),
                        const SizedBox(height: 16),
                      ],
                      _buildHeaderCard(locked, isMobile),
                      const SizedBox(height: 20),
                      if (!_isOnAccount) _buildAgainstBillSection(locked),
                      if (_isOnAccount)  _buildOnAccountSection(locked),
                      const SizedBox(height: 12),
                      _buildTotalsBar(),
                      if (_actionError != null) ...[
                        const SizedBox(height: 12),
                        _errorBanner(_actionError!),
                      ],
                      if (canSave || canApprove) ...[
                        const SizedBox(height: 20),
                        _buildActionButtons(canSave: canSave, canApprove: canApprove),
                      ],
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  // ── Header card ───────────────────────────────────────────────────────────

  Widget _buildHeaderCard(bool locked, bool isMobile) {
    final isCash = _voucherType != null && isCashVoucher(_voucherType!);
    final showRateField = _transCurrency.isNotEmpty && _transCurrency != _baseCurrency;

    // Every field in every row is constrained to exactly this height.
    // This is the only reliable cross-platform way to guarantee uniformity:
    // IntrinsicHeight equalises within a row but not between rows, because
    // DropdownButtonFormField reports a larger intrinsic height than TextFormField.
    const fh = 56.0;

    const dec = InputDecoration(
      border: OutlineInputBorder(),
      isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
    );

    Widget field(Widget child) => SizedBox(height: fh, child: child);

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
          Builder(builder: (_) {
            final f1 = field(DropdownButtonFormField<String>(
              decoration: dec.copyWith(labelText: 'Voucher Type *'),
              value: _voucherType,
              isExpanded: true,
              items: _supportedTypes.map((t) => DropdownMenuItem(
                value: t,
                child: Text('$t — ${_typeLabels[t]}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13)),
              )).toList(),
              onChanged: locked ? null : (v) { if (v != null) _applyVoucherType(v); },
            ));
            final f2 = field(InputDecorator(
              decoration: dec.copyWith(labelText: 'Voucher No'),
              child: Text(
                _voucherNo ?? '(auto on save)',
                style: TextStyle(
                    fontSize: 13,
                    color: _voucherNo != null
                        ? AppColors.textPrimary
                        : AppColors.textDisabled),
              ),
            ));
            final f3 = field(InkWell(
              onTap: locked
                  ? null
                  : () => _pickDate(_transDate, (d) => setState(() => _transDate = d)),
              child: InputDecorator(
                decoration: dec.copyWith(
                  labelText: 'Date *',
                  suffixIcon: Icon(Icons.calendar_today_outlined,
                      size: 15,
                      color: locked ? AppColors.textDisabled : AppColors.primary),
                ),
                child: Text(_displayDate(_transDate),
                    style: const TextStyle(fontSize: 13)),
              ),
            ));
            if (isMobile) {
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: double.infinity, child: f1),
                const SizedBox(height: 8),
                Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                  Expanded(child: f2),
                  const SizedBox(width: 12),
                  Expanded(child: f3),
                ]),
              ]);
            }
            return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Expanded(flex: 4, child: f1),
              const SizedBox(width: 12),
              Expanded(flex: 3, child: f2),
              const SizedBox(width: 12),
              Expanded(flex: 3, child: f3),
            ]);
          }),

          const SizedBox(height: 12),

          // Row 2: Cash/Bank Account | Currency | Rate (1 base = X trans)
          Builder(builder: (_) {
            final f1 = _buildAccountSearch(
              accounts: _cashBankList,
              selectedId: _cashBankId,
              locked: locked,
              height: fh,
              decoration: dec.copyWith(
                  labelText: isCash ? 'Cash Account *' : 'Bank Account *'),
              onSelected: _onCashBankSelected,
              onCleared: () => setState(() {
                _cashBankId    = null;
                _transCurrency = '';
                _rateCtrl.text = '1';
              }),
            );
            final currChip = SizedBox(
              width: 80,
              height: fh,
              child: InputDecorator(
                decoration: dec.copyWith(labelText: 'Currency'),
                child: Text(
                  _transCurrency.isEmpty ? '—' : _transCurrency,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            );
            final rateField = field(TextFormField(
              controller: _rateCtrl,
              enabled: !locked && showRateField,
              decoration: dec.copyWith(
                labelText: showRateField ? '1 $_baseCurrency = ' : 'Rate',
                hintText: '1.0',
              ),
              style: const TextStyle(fontSize: 13),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
              onChanged: (_) => setState(() {}),
            ));
            if (isMobile) {
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: double.infinity, child: f1),
                const SizedBox(height: 8),
                Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                  currChip,
                  const SizedBox(width: 12),
                  Expanded(child: rateField),
                ]),
              ]);
            }
            return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Expanded(flex: 5, child: f1),
              const SizedBox(width: 12),
              currChip,
              const SizedBox(width: 12),
              Expanded(flex: 2, child: rateField),
            ]);
          }),

          const SizedBox(height: 12),

          // Row 3: Payment Mode | Ref No | Ref Date | Remarks
          Builder(builder: (_) {
            final f1 = field(DropdownButtonFormField<String>(
              decoration: dec.copyWith(labelText: 'Payment Mode'),
              value: _paymentMode,
              isExpanded: true,
              items: _paymentModes.map((m) => DropdownMenuItem(
                value: m['payment_mode_code'] as String,
                child: Text(m['payment_mode_name'] as String,
                    style: const TextStyle(fontSize: 13)),
              )).toList(),
              onChanged: (locked || isCash)
                  ? null
                  : (v) => setState(() => _paymentMode = v),
            ));
            final f2 = field(TextFormField(
              controller: _refNoCtrl,
              enabled: !locked,
              decoration: dec.copyWith(labelText: 'Ref No'),
              style: const TextStyle(fontSize: 13),
            ));
            final f3 = field(InkWell(
              onTap: locked
                  ? null
                  : () => _pickDate(_refDate, (d) => setState(() => _refDate = d)),
              child: InputDecorator(
                decoration: dec.copyWith(
                  labelText: 'Ref Date',
                  suffixIcon: Icon(Icons.calendar_today_outlined,
                      size: 15,
                      color: locked ? AppColors.textDisabled : AppColors.primary),
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
            ));
            final f4 = field(TextFormField(
              controller: _remarksCtrl,
              enabled: !locked,
              decoration: dec.copyWith(labelText: 'Remarks'),
              style: const TextStyle(fontSize: 13),
            ));
            if (isMobile) {
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: double.infinity, child: f1),
                const SizedBox(height: 8),
                Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                  Expanded(child: f2),
                  const SizedBox(width: 12),
                  Expanded(child: f3),
                ]),
                const SizedBox(height: 8),
                SizedBox(width: double.infinity, child: f4),
              ]);
            }
            return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Expanded(flex: 2, child: f1),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: f2),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: f3),
              const SizedBox(width: 12),
              Expanded(flex: 3, child: f4),
            ]);
          }),

          // Cheque row — only for CHEQUE payment mode
          if (_paymentMode == 'CHEQUE') ...[
            const SizedBox(height: 12),
            Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Expanded(
                child: field(TextFormField(
                  controller: _chequeNoCtrl,
                  enabled: !locked,
                  decoration: dec.copyWith(labelText: 'Cheque No'),
                  style: const TextStyle(fontSize: 13),
                )),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: field(InkWell(
                  onTap: locked
                      ? null
                      : () => _pickDate(
                          _chequeDate ?? _transDate,
                          (d) => setState(() => _chequeDate = d)),
                  child: InputDecorator(
                    decoration: dec.copyWith(
                      labelText: 'Cheque Date',
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
                )),
              ),
            ]),
          ],

          const SizedBox(height: 12),

          // Row 4: Against Bill | On Account toggle
          // Against Bill is only valid for Receipt+Customer or Payment+Supplier.
          Builder(builder: (_) {
            final billAllowed = _canAgainstBill;
            final whyDisabled = _partyNature.isNotEmpty && !billAllowed
                ? ((_voucherType == 'CRV' || _voucherType == 'BRV')
                    ? 'Receipts from suppliers cannot be settled against a bill'
                    : 'Payments to customers cannot be settled against a bill')
                : null;
            return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Radio<bool>(
                value: false,
                groupValue: _isOnAccount,
                onChanged: (locked || !billAllowed)
                    ? null
                    : (v) { if (v != null) setState(() => _isOnAccount = v); },
              ),
              Text(
                'Against Bill',
                style: TextStyle(
                    fontSize: 13,
                    color: (locked || !billAllowed)
                        ? AppColors.textDisabled
                        : AppColors.textPrimary),
              ),
              if (whyDisabled != null) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message: whyDisabled,
                  child: const Icon(Icons.info_outline,
                      size: 14, color: AppColors.textSecondary),
                ),
              ],
              const SizedBox(width: 20),
              Radio<bool>(
                value: true,
                groupValue: _isOnAccount,
                onChanged: locked
                    ? null
                    : (v) { if (v != null) setState(() => _isOnAccount = v); },
              ),
              const Text('On Account', style: TextStyle(fontSize: 13)),
            ]);
          }),
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
        _buildAccountSearch(
          accounts: _eligiblePartyAccounts,
          selectedId: _partyId,
          locked: locked,
          decoration: InputDecoration(
              labelText: _voucherType == null
                  ? 'Customer / Supplier *'
                  : isReceiptVoucher(_voucherType!)
                      ? 'Customer *'
                      : 'Supplier *',
              border: const OutlineInputBorder(),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
          onSelected: _onPartySelected,
          onCleared: () {
            for (final b in _bills) b.dispose();
            setState(() {
              _partyId       = null;
              _partyName     = null;
              _partyCurrency = '';
              _partyRate     = 1.0;
              _bills         = [];
            });
          },
        ),

        if (_partyCurrency.isNotEmpty && _partyCurrency != transCurr) ...[
          const SizedBox(height: 6),
          Text(
            'Party currency: $_partyCurrency  ·  '
            '1 $transCurr = ${_fmtRate(_partyRate)} $_partyCurrency',
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
    final tc   = _transCurrency.isEmpty ? _baseCurrency : _transCurrency;
    const btnW = 32.0;

    Widget colHeader(String label, {TextAlign align = TextAlign.left}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 4, left: 2),
          child: Text(label,
              textAlign: align,
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary)),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title row + Add Line button
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
        const SizedBox(height: 4),

        // Column headers (shown once above the data rows)
        Row(children: [
          Expanded(flex: 4, child: colHeader('Account')),
          const SizedBox(width: 12),
          Expanded(flex: 2, child: colHeader('Amount ($tc)', align: TextAlign.right)),
          const SizedBox(width: 12),
          Expanded(flex: 3, child: colHeader('Remarks')),
          // ignore: prefer_const_constructors — btnW is runtime, cannot be const
          if (!locked) SizedBox(width: btnW + 8),
        ]),

        // Data rows — no floating labels, compact inputs
        ..._accountLines.asMap().entries.map((e) {
          final i    = e.key;
          final line = e.value;
          final lineCurr = line.accountCurrency.isEmpty ? _baseCurrency : line.accountCurrency;
          final showCurrChip = lineCurr.isNotEmpty && lineCurr != tc;

          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                  Expanded(
                    flex: 4,
                    child: _buildAccountSearch(
                      accounts: _otherAccounts
                          .where((a) => !_accountLines
                              .where((l) => l != line)
                              .any((l) => l.accountId == a['id'] as String))
                          .toList(),
                      selectedId: line.accountId,
                      locked: locked,
                      height: 44,
                      keyValue: '${i}_${line.accountId ?? 'none'}',
                      decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          isDense: true,
                          contentPadding:
                              EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                          hintText: 'Search account'),
                      onSelected: (a) {
                        final acCurr = _extractCurrency(a);
                        final trans  = _transCurrency.isEmpty ? _baseCurrency : _transCurrency;
                        setState(() {
                          line.accountId       = a['id'] as String;
                          line.accountName     = a['account_name'] as String?;
                          line.accountCurrency = acCurr;
                          line.partyRate       = acCurr == trans ? 1.0 : 1.0;
                        });
                        if (acCurr.isNotEmpty && acCurr != trans) {
                          unawaited(_fetchCrossRate(trans, acCurr).then((r) {
                            if (mounted && r != null) setState(() => line.partyRate = r);
                          }));
                        }
                      },
                      onCleared: () => setState(() {
                        line.accountId       = null;
                        line.accountName     = null;
                        line.accountCurrency = '';
                      }),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Amount column — shows currency chip when account currency ≠ trans currency
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: 44,
                      child: TextFormField(
                        controller: line.amountCtrl,
                        enabled: !locked,
                        textAlign: TextAlign.right,
                        decoration: InputDecoration(
                            border: const OutlineInputBorder(),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 10),
                            suffixText: showCurrChip ? lineCurr : null,
                            suffixStyle: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppColors.secondary)),
                        style: const TextStyle(fontSize: 13),
                        keyboardType:
                            const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))
                        ],
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: SizedBox(
                      height: 44,
                      child: TextFormField(
                        controller: line.remarksCtrl,
                        enabled: !locked,
                        decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            isDense: true,
                            contentPadding:
                                EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                            hintText: 'Remarks'),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                  if (!locked) ...[
                    const SizedBox(width: 8),
                    SizedBox(
                      width: btnW,
                      child: _accountLines.length > 1
                          ? IconButton(
                              onPressed: () {
                                final removed = _accountLines.removeAt(i);
                                removed.dispose();
                                setState(() {});
                              },
                              icon: const Icon(Icons.remove_circle_outline,
                                  size: 18, color: AppColors.negative),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
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

  Widget _buildActionButtons({
    required bool canSave,
    required bool canApprove,
  }) {
    return Row(children: [
      if (canSave)
        OutlinedButton.icon(
          onPressed: (_saving || _posting) ? null : _saveDraft,
          icon: _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.save_outlined, size: 16),
          label: Text(_saving ? 'Saving…' : 'Save Draft'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(140, 48)),
        ),
      if (canSave && canApprove) const SizedBox(width: 12),
      if (canApprove)
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
            minimumSize: const Size(140, 48),
          ),
        ),
    ]);
  }

  // ── Utility widgets ───────────────────────────────────────────────────────

  Widget _errorBanner(String msg, {VoidCallback? onRetry}) => Container(
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
              style: const TextStyle(color: AppColors.negative, fontSize: 13))),
      if (onRetry != null) ...[
        const SizedBox(width: 8),
        TextButton(
          onPressed: onRetry,
          style: TextButton.styleFrom(
            foregroundColor: AppColors.negative,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('Retry',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      ],
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
