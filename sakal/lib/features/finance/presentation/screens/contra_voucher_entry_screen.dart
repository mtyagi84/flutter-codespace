import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/layout/screen_header.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../core/utils/app_number_format.dart';
import '../../../../core/utils/local_id.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/sakal_field_card.dart';
import '../../../../core/widgets/sakal_field_row.dart';
import '../../../../core/widgets/sakal_header_action_button.dart';
import '../../../../core/widgets/sakal_reciprocal_rate_field.dart';
import '../../../../core/printing/print_engine.dart';
import '../../../../core/printing/print_template_provider.dart';
import '../../domain/repositories/finance_voucher_repository.dart';
import '../providers/finance_voucher_providers.dart';
import '../widgets/finance_account_picker.dart';

/// Contra Voucher — Cash↔Cash, Bank↔Bank, Cash→Bank (deposit),
/// Bank→Cash (withdrawal). A two-block From/To transfer, never a
/// JV-style free-form line grid — direction is always implicit
/// (FROM=CR, TO=DR), never a field the user picks. See
/// docs/screens/contra_voucher.md for the full design discussion
/// (Odoo's independently-editable From/To amounts + Zoho's optional
/// Transfer Charge, both adopted here).
class ContraVoucherEntryScreen extends ConsumerStatefulWidget {
  final String? editTransNo;
  final String? editTransDate;
  const ContraVoucherEntryScreen({super.key, this.editTransNo, this.editTransDate});

  @override
  ConsumerState<ContraVoucherEntryScreen> createState() => _ContraVoucherEntryScreenState();
}

class _ContraVoucherEntryScreenState extends ConsumerState<ContraVoucherEntryScreen>
    with ScreenPermissionMixin<ContraVoucherEntryScreen>, ScreenHeaderMixin<ContraVoucherEntryScreen> {
  @override
  String get screenName => RouteNames.contraVoucherList;

  @override
  ScreenHeaderInfo buildScreenHeader() {
    // Desktop-only consolidation into the TopBar (see PO/GRN/Sales Order
    // pilots) — mobile keeps the body-level Wrap row unchanged.
    final showDesktopActions = !Responsive.isMobile(context);
    final canSaveNow = !_locked && (_isNew ? canAdd : canEdit);
    final showApproveNow = !_locked && canApprove && !_isNew;
    final showReverseNow = _locked && canApprove;
    final showCopyNow = !_locked && !_isNew;
    return ScreenHeaderInfo(
      title: _transNo ?? 'New Contra Voucher',
      subtitle: _flavorLabel,
      badgeText: _isPosted ? 'Posted' : 'Draft',
      badgeColor: _isPosted ? AppColors.positive : AppColors.secondary,
      actions: showDesktopActions
          ? [
              if (showCopyNow)
                SakalHeaderActionButton(label: 'Copy', icon: Icons.copy_outlined, kind: SakalActionKind.neutral, onPressed: _applyCopy),
              if (showReverseNow)
                SakalHeaderActionButton(label: 'Reverse', icon: Icons.undo, kind: SakalActionKind.neutral, loading: _reversing, onPressed: _reversing ? null : _reverse),
              if (canSaveNow)
                SakalHeaderActionButton(label: 'Save Draft', icon: Icons.save_outlined, kind: SakalActionKind.save, loading: _saving, onPressed: _saving ? null : () => _saveDraft()),
              if (showApproveNow)
                SakalHeaderActionButton(label: 'Approve', icon: Icons.check_circle_outline, kind: SakalActionKind.approve, loading: _approving, onPressed: _approving ? null : _approve),
              if (_transNo != null)
                SakalHeaderActionButton(label: 'Print', icon: Icons.print_outlined, kind: SakalActionKind.neutral, loading: _printing, onPressed: _printing ? null : _print),
            ]
          : (_transNo != null ? [_buildPrintButton()] : const []),
    );
  }

  FinanceVoucherRepository get _ds => ref.read(financeVoucherRepositoryProvider);

  String? _transNo;
  DateTime _transDate = DateTime.now();
  bool _isPosted = false;
  // Set only by _reverse() (client-side draft, see that method) so the
  // eventual Save carries this traceability tag through to
  // fn_save_finance_voucher's header JSONB — same key fn_reverse_voucher
  // itself used to set server-side. Cleared by _applyCopy().
  String? _reversalOfTransNo;
  String? _locationId;
  // Location picker only matters (and only renders) under INTER_ENTITY
  // accounting — see CLAUDE.md's "Inter-Location Model". Under SIMPLE
  // (the default) these stay at their defaults and nothing changes.
  String _interLocationModel = 'SIMPLE';
  List<Map<String, dynamic>> _accessibleLocations = const [];

  String _baseCcy = '';
  String _localCcy = '';
  List<Map<String, dynamic>> _allAccounts = [];

  // Only Cash/Bank accounts are pickable for FROM/TO — the mirror-image
  // exclusion of Journal Voucher's own picker, which excludes them.
  List<Map<String, dynamic>> get _cashBankAccounts =>
      _allAccounts.where((a) => (a['account_nature'] == 'Cash' || a['account_nature'] == 'Bank') && a['posting_allowed'] == true).toList();
  // The transfer-charge line needs a normal Expense/General account —
  // never Cash/Bank (that would just be a second, unrelated transfer).
  List<Map<String, dynamic>> get _chargeAccounts =>
      _allAccounts.where((a) => a['account_nature'] != 'Cash' && a['account_nature'] != 'Bank' && a['posting_allowed'] == true).toList();

  // ── FROM (money leaves — always CR) ──────────────────────────────────
  String? _fromAccountId;
  String _fromAccountDisplay = '';
  String _fromNature = '';
  String _fromCurrency = '';
  final _fromAmountCtrl = TextEditingController();
  final _baseRateCtrl = TextEditingController(text: '1');
  final _localRateCtrl = TextEditingController(text: '1');

  // ── TO (money arrives — always DR) ───────────────────────────────────
  String? _toAccountId;
  String _toAccountDisplay = '';
  String _toNature = '';
  String _toCurrency = '';
  final _toAmountCtrl = TextEditingController();
  double? _fromToRate; // rate(Ccy_F -> Ccy_T), fetched once, used only to SUGGEST the To Amount
  bool _toAmountManuallyEdited = false;

  // ── Transfer Charge (optional — only when From/To amounts don't reconcile) ──
  bool _showCharge = false;
  String? _chargeAccountId;
  String _chargeAccountDisplay = '';
  String _chargeAccountCurrency = '';
  double _chargePartyRateFetched = 1;
  final _chargeAmountCtrl = TextEditingController();
  bool _chargeAmountManuallyEdited = false;

  final _refNoCtrl = TextEditingController();
  DateTime? _refDate;
  final _remarksCtrl = TextEditingController();

  final _fromAccountFocusNode = FocusNode();
  final _fromAmountFocusNode = FocusNode();
  final _toAccountFocusNode = FocusNode();
  final _toAmountFocusNode = FocusNode();
  final _remarksFocusNode = FocusNode();

  bool _loading = true;
  String? _error;
  String? _actionError;
  bool _saving = false;
  bool _approving = false;
  final bool _reversing = false;
  bool _printing = false;

  String _preparedByName = '';
  String _approvedByName = '';

  bool get _isNew => _transNo == null;
  bool get _locked => _isPosted;

  double get _fromAmount => double.tryParse(_fromAmountCtrl.text) ?? 0;
  double get _toAmountEntered => double.tryParse(_toAmountCtrl.text) ?? 0;
  double get _baseRate => double.tryParse(_baseRateCtrl.text) ?? 1;
  double get _localRate => double.tryParse(_localRateCtrl.text) ?? 1;

  /// The To line's trans_amount, expressed back in the voucher's one
  /// trans_currency (Ccy_F) — NOT the same as _toAmountEntered whenever
  /// currencies differ. See docs/screens/contra_voucher.md Q2.
  double get _toTransAmount {
    if (_fromCurrency.isEmpty || _fromCurrency == _toCurrency) return _toAmountEntered;
    final r = _fromToRate;
    if (r == null || r == 0) return _fromAmount;
    return _toAmountEntered / r;
  }

  /// Positive = value was lost in transit (shortfall, DR charge line).
  /// Negative = a favorable variance (CR charge line). ~0 = no charge needed.
  double get _gap => _fromAmount - _toTransAmount;
  bool get _gapExists => _fromAccountId != null && _toAccountId != null && _fromAmount > 0 && _gap.abs() > 0.01;

  double get _chargePartyRate {
    if (_chargeAccountCurrency.isEmpty || _chargeAccountCurrency == _fromCurrency) return 1;
    if (_chargeAccountCurrency == _baseCcy) return _baseRate;
    if (_chargeAccountCurrency == _localCcy) return _localRate;
    return _chargePartyRateFetched;
  }

  String get _flavorLabel {
    if (_fromAccountId == null || _toAccountId == null) return 'Contra Voucher';
    final fromCash = _fromNature == 'Cash';
    final toCash = _toNature == 'Cash';
    if (fromCash && toCash) return 'Cash Transfer';
    if (!fromCash && !toCash) return 'Bank Transfer';
    if (fromCash && !toCash) return 'Deposit';
    return 'Withdrawal';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _init();
      _fromAccountFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _fromAmountCtrl.dispose();
    _baseRateCtrl.dispose();
    _localRateCtrl.dispose();
    _toAmountCtrl.dispose();
    _chargeAmountCtrl.dispose();
    _refNoCtrl.dispose();
    _remarksCtrl.dispose();
    _fromAccountFocusNode.dispose();
    _fromAmountFocusNode.dispose();
    _toAccountFocusNode.dispose();
    _toAmountFocusNode.dispose();
    _remarksFocusNode.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final session = ref.read(sessionProvider)!;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _locationId = session.locationId;
      _interLocationModel = await ref.read(interLocationModelProvider.future);
      if (_interLocationModel == 'INTER_ENTITY') {
        _accessibleLocations = await ref.read(userAccessibleLocationsProvider.future);
      }
      _baseCcy = await ref.read(baseCurrencyProvider.future);
      _localCcy = await ref.read(localCurrencyProvider.future);
      _allAccounts = await ref.read(accountsProvider.future);

      // Same fix as Expense/Journal Voucher's identical bug: a freshly-
      // created-then-saved-then-approved voucher (same screen instance)
      // has its trans_no in _transNo, not widget.editTransNo (immutable
      // constructor param) — re-reading only the latter silently skipped
      // this reload, so the post-approve status never reached the screen.
      final effectiveTransNo = widget.editTransNo ?? _transNo;
      final effectiveTransDate = widget.editTransNo != null ? widget.editTransDate : (_transNo != null ? _fmtDate(_transDate) : null);
      if (effectiveTransNo != null) {
        final header = await _ds.getHeader(clientId: session.clientId, companyId: session.companyId, transNo: effectiveTransNo, transDate: effectiveTransDate);
        if (header != null) {
          _transNo = header.transNo;
          _transDate = DateTime.parse(header.transDate);
          _isPosted = header.isPosted;
          _refNoCtrl.text = header.referenceNo;
          _refDate = header.referenceDate.isNotEmpty ? DateTime.tryParse(header.referenceDate) : null;
          _remarksCtrl.text = header.remarks;
          _locationId = header.locationId;

          final lines = await _ds.getLines(clientId: session.clientId, companyId: session.companyId, transNo: _transNo!, transDate: _fmtDate(_transDate));
          // Keyed by each line's own serial_no, not iteration order:
          // serial_no 1 = FROM, 2 = TO, 3 (if present) = the Transfer
          // Charge line — robust even in the rare "excess" case where the
          // charge line is itself CR.
          for (final l in lines) {
            final account = _allAccounts.firstWhere((a) => a['id'] == l.accountId, orElse: () => const {});
            final accCcy = (account['rim_currencies'] as Map<String, dynamic>?)?['currency_id'] as String? ?? '';
            if (l.serialNo == 1) {
              _fromAccountId = l.accountId;
              _fromAccountDisplay = account.isNotEmpty ? FinanceAccountPicker.displayString(account) : '';
              _fromNature = account['account_nature'] as String? ?? '';
              _fromCurrency = accCcy;
              _fromAmountCtrl.text = _fmtNum(l.transAmount);
              _baseRateCtrl.text = _fmtRate(l.baseRate);
              _localRateCtrl.text = _fmtRate(l.localRate);
            } else if (l.serialNo == 2) {
              _toAccountId = l.accountId;
              _toAccountDisplay = account.isNotEmpty ? FinanceAccountPicker.displayString(account) : '';
              _toNature = account['account_nature'] as String? ?? '';
              _toCurrency = accCcy;
              _toAmountCtrl.text = _fmtNum(l.partyAmount);
              _toAmountManuallyEdited = true;
              if (_fromCurrency != _toCurrency && l.transAmount > 0) {
                _fromToRate = l.partyAmount / l.transAmount;
              }
            } else {
              _showCharge = true;
              _chargeAccountId = l.accountId;
              _chargeAccountDisplay = account.isNotEmpty ? FinanceAccountPicker.displayString(account) : '';
              _chargeAccountCurrency = accCcy;
              _chargeAmountCtrl.text = _fmtNum(l.transAmount);
              _chargeAmountManuallyEdited = true;
              _chargePartyRateFetched = l.partyRate;
            }
          }
          _preparedByName = header.createdByName;
          _approvedByName = header.postedByName;
        }
      }

      if (mounted) setState(() => _loading = false);
    } catch (e, st) {
      AppLogger.error('ContraVoucherLoad', e, st);
      if (mounted) {
        setState(() {
          _loading = false;
          _error = ErrorPresenter.format(e, action: 'load this voucher');
        });
      }
    }
  }

  // ── FROM / TO account selection ─────────────────────────────────────

  Future<void> _onFromSelected(Map<String, dynamic> account) async {
    setState(() {
      _fromAccountId = account['id'] as String?;
      _fromAccountDisplay = FinanceAccountPicker.displayString(account);
      _fromNature = account['account_nature'] as String? ?? '';
      _fromCurrency = (account['rim_currencies'] as Map<String, dynamic>?)?['currency_id'] as String? ?? '';
    });
    await _refreshBaseLocalRates();
    await _refreshFromToRate();
    _recomputeSuggestedToAmount();
    // Only matters when the user already typed a manual To Amount before
    // (re)picking From — the suggestion above is a no-op in that case, so
    // a genuine gap against the NEW From currency/amount must be re-checked.
    _recomputeSuggestedCharge();
    if (mounted) setState(() {});
    _fromAmountFocusNode.requestFocus();
  }

  /// Re-fetches the From-currency's rate to Base/Local. Pulled out of
  /// _onFromSelected so both a real account pick AND a voucher-date change
  /// (_pickDate) or a swap (_swapFromTo) can refresh rates without faking
  /// up an account map — passing one with blank account_code/account_name
  /// into _onFromSelected would silently corrupt _fromAccountDisplay to
  /// "[] ", a real bug caught in this screen's own review pass.
  Future<void> _refreshBaseLocalRates() async {
    if (_locationId == null || _fromCurrency.isEmpty) return;
    final session = ref.read(sessionProvider)!;
    if (_fromCurrency == _baseCcy) {
      _baseRateCtrl.text = '1';
    } else {
      final r = await _ds.fetchExchangeRate(companyId: session.companyId, locationId: _locationId!, fromCurrency: _fromCurrency, toCurrency: _baseCcy, rateDate: _fmtDate(_transDate));
      _baseRateCtrl.text = _fmtRate(r ?? 1);
    }
    if (_fromCurrency == _localCcy) {
      _localRateCtrl.text = '1';
    } else {
      final r = await _ds.fetchExchangeRate(companyId: session.companyId, locationId: _locationId!, fromCurrency: _fromCurrency, toCurrency: _localCcy, rateDate: _fmtDate(_transDate));
      _localRateCtrl.text = _fmtRate(r ?? 1);
    }
  }

  Future<void> _onToSelected(Map<String, dynamic> account) async {
    setState(() {
      _toAccountId = account['id'] as String?;
      _toAccountDisplay = FinanceAccountPicker.displayString(account);
      _toNature = account['account_nature'] as String? ?? '';
      _toCurrency = (account['rim_currencies'] as Map<String, dynamic>?)?['currency_id'] as String? ?? '';
      _toAmountManuallyEdited = false;
    });
    await _refreshFromToRate();
    _recomputeSuggestedToAmount();
    if (mounted) setState(() {});
    _toAmountFocusNode.requestFocus();
  }

  Future<void> _refreshFromToRate() async {
    if (_fromAccountId == null || _toAccountId == null || _fromCurrency.isEmpty || _toCurrency.isEmpty || _locationId == null) {
      return;
    }
    if (_fromCurrency == _toCurrency) {
      _fromToRate = 1;
      return;
    }
    final session = ref.read(sessionProvider)!;
    final r = await _ds.fetchExchangeRate(companyId: session.companyId, locationId: _locationId!, fromCurrency: _fromCurrency, toCurrency: _toCurrency, rateDate: _fmtDate(_transDate));
    _fromToRate = r ?? 1;
  }

  /// Pre-fills To Amount from From Amount x the fetched rate — a pure
  /// starting suggestion. Never overwrites a value the user already
  /// typed themselves (_toAmountManuallyEdited), matching Odoo's own
  /// "editable, not locked" idea this screen is built around.
  void _recomputeSuggestedToAmount() {
    if (_toAmountManuallyEdited || _fromAccountId == null || _toAccountId == null) return;
    final rate = _fromCurrency == _toCurrency ? 1.0 : (_fromToRate ?? 1.0);
    _toAmountCtrl.text = _fmtNum(_fromAmount * rate);
  }

  void _onFromAmountChanged(String _) {
    _recomputeSuggestedToAmount();
    _recomputeSuggestedCharge();
    setState(() {});
  }

  void _onToAmountChanged(String _) {
    _toAmountManuallyEdited = true;
    _recomputeSuggestedCharge();
    setState(() {});
  }

  Future<void> _onChargeSelected(Map<String, dynamic> account) async {
    final session = ref.read(sessionProvider)!;
    setState(() {
      _chargeAccountId = account['id'] as String?;
      _chargeAccountDisplay = FinanceAccountPicker.displayString(account);
      _chargeAccountCurrency = (account['rim_currencies'] as Map<String, dynamic>?)?['currency_id'] as String? ?? '';
    });
    if (_chargeAccountCurrency.isNotEmpty &&
        _chargeAccountCurrency != _fromCurrency &&
        _chargeAccountCurrency != _baseCcy &&
        _chargeAccountCurrency != _localCcy &&
        _locationId != null) {
      final r = await _ds.fetchExchangeRate(companyId: session.companyId, locationId: _locationId!, fromCurrency: _fromCurrency, toCurrency: _chargeAccountCurrency, rateDate: _fmtDate(_transDate));
      _chargePartyRateFetched = r ?? 1;
    }
    if (mounted) setState(() {});
  }

  /// Auto-suggests the charge amount from the live-computed gap, unless
  /// the user has already typed their own number into that field.
  void _recomputeSuggestedCharge() {
    if (_chargeAmountManuallyEdited) return;
    if (_gapExists) {
      _chargeAmountCtrl.text = _fmtNum(_gap.abs());
      if (!_showCharge) _showCharge = true;
      _resolveChargeAccountDefault();
    } else if (_showCharge && _chargeAccountId == null) {
      _chargeAmountCtrl.clear();
    }
  }

  Future<void> _resolveChargeAccountDefault() async {
    if (_chargeAccountId != null) return; // never override a real pick
    final session = ref.read(sessionProvider)!;
    try {
      final id = await _ds.resolveCompanyAccountLink(clientId: session.clientId, companyId: session.companyId, linkKey: 'EXCHANGE_GAIN_LOSS_ACCOUNT');
      if (id == null || !mounted) return;
      final account = _allAccounts.firstWhere((a) => a['id'] == id, orElse: () => const {});
      if (account.isEmpty) return;
      setState(() {
        _chargeAccountId = id;
        _chargeAccountDisplay = FinanceAccountPicker.displayString(account);
        _chargeAccountCurrency = (account['rim_currencies'] as Map<String, dynamic>?)?['currency_id'] as String? ?? '';
      });
    } catch (_) {
      // No default configured — the user picks manually, same convention
      // as every other "callers must treat NULL as a hard requirement to
      // ask the user" account-link consumer in this app.
    }
  }

  void _addChargeManually() {
    setState(() {
      _showCharge = true;
      _chargeAmountManuallyEdited = true;
    });
  }

  void _removeCharge() {
    setState(() {
      _showCharge = false;
      _chargeAccountId = null;
      _chargeAccountDisplay = '';
      _chargeAccountCurrency = '';
      _chargeAmountCtrl.clear();
      _chargeAmountManuallyEdited = false;
    });
  }

  Future<void> _swapFromTo() async {
    setState(() {
      final fId = _fromAccountId, fDisp = _fromAccountDisplay, fNat = _fromNature, fCcy = _fromCurrency;
      final fAmt = _fromAmountCtrl.text;
      _fromAccountId = _toAccountId; _fromAccountDisplay = _toAccountDisplay; _fromNature = _toNature; _fromCurrency = _toCurrency;
      _fromAmountCtrl.text = _toAmountCtrl.text;
      _toAccountId = fId; _toAccountDisplay = fDisp; _toNature = fNat; _toCurrency = fCcy;
      _toAmountCtrl.text = fAmt;
      _toAmountManuallyEdited = true;
      if (_fromToRate != null && _fromToRate != 0) _fromToRate = 1 / _fromToRate!;
    });
    await _refreshBaseLocalRates();
    _recomputeSuggestedCharge();
    if (mounted) setState(() {});
  }

  // ── Save / Approve / Copy / Reverse ─────────────────────────────────

  Future<bool> _saveDraft() async {
    if (_interLocationModel == 'INTER_ENTITY' && _locationId == null) {
      _showSnack('Select a location.', color: AppColors.negative);
      return false;
    }
    if (_fromAccountId == null || _toAccountId == null) {
      _showSnack('Pick both a From and a To account.', color: AppColors.negative);
      return false;
    }
    if (_fromAccountId == _toAccountId) {
      _showSnack('From and To must be different accounts.', color: AppColors.negative);
      return false;
    }
    if (_fromAmount <= 0 || _toAmountEntered <= 0) {
      _showSnack('Enter both amounts.', color: AppColors.negative);
      return false;
    }
    final needsCharge = _gapExists;
    if (needsCharge && _chargeAccountId == null) {
      _showSnack('The From and To amounts don\'t reconcile — pick an account for the ${_gap > 0 ? "Transfer Charge" : "Exchange Gain"} to continue.', color: AppColors.negative);
      return false;
    }

    setState(() {
      _saving = true;
      _actionError = null;
    });
    final session = ref.read(sessionProvider)!;
    try {
      Map<String, dynamic> buildHeader() => {
            'client_id': session.clientId,
            'company_id': session.companyId,
            'location_id': _locationId,
            'trans_no': _transNo ?? '',
            'trans_date': _fmtDate(_transDate),
            'voucher_type_code': 'CTR',
            'is_on_account': true,
            'reference_no': _refNoCtrl.text.trim(),
            'reference_date': _refDate != null ? _fmtDate(_refDate!) : '',
            'remarks': _remarksCtrl.text.trim(),
            if (_reversalOfTransNo != null) 'reversal_of_trans_no': _reversalOfTransNo,
          };

      final lines = <Map<String, dynamic>>[
        {
          'serial_no': 1,
          'account_id': _fromAccountId,
          'trans_nature': 'CR',
          'trans_amount': _fromAmount,
          'trans_currency': _fromCurrency,
          'base_amount': _fromAmount * _baseRate,
          'base_rate': _baseRate,
          'local_amount': _fromAmount * _localRate,
          'local_rate': _localRate,
          'party_amount': _fromAmount,
          'party_currency': _fromCurrency,
          'party_rate': 1,
          'line_remarks': _flavorLabel,
        },
        {
          'serial_no': 2,
          'account_id': _toAccountId,
          'trans_nature': 'DR',
          'trans_amount': _toTransAmount,
          'trans_currency': _fromCurrency,
          'base_amount': _toTransAmount * _baseRate,
          'base_rate': _baseRate,
          'local_amount': _toTransAmount * _localRate,
          'local_rate': _localRate,
          'party_amount': _toAmountEntered,
          'party_currency': _toCurrency,
          'party_rate': _fromCurrency == _toCurrency ? 1 : (_fromToRate ?? 1),
          'line_remarks': _flavorLabel,
        },
      ];
      if (needsCharge) {
        final chargeAmt = _gap.abs();
        lines.add({
          'serial_no': 3,
          'account_id': _chargeAccountId,
          'trans_nature': _gap > 0 ? 'DR' : 'CR',
          'trans_amount': chargeAmt,
          'trans_currency': _fromCurrency,
          'base_amount': chargeAmt * _baseRate,
          'base_rate': _baseRate,
          'local_amount': chargeAmt * _localRate,
          'local_rate': _localRate,
          'party_amount': chargeAmt * _chargePartyRate,
          'party_currency': _chargeAccountCurrency.isEmpty ? _fromCurrency : _chargeAccountCurrency,
          'party_rate': _chargePartyRate,
          'line_remarks': 'Transfer charge / adjustment',
        });
      }

      if (session.offlineMode) {
        final localId = generateLocalId();
        await ref.read(syncEngineProvider).enqueue(
          documentType: 'FINANCE_VOUCHER',
          documentId: localId,
          endpoint: '/rpc/fn_save_finance_voucher',
          payload: {'p_header': buildHeader(), 'p_lines': lines, 'p_user_id': session.userId},
        );
        await _ds.cacheVoucherLocally(effectiveTransNo: localId, header: buildHeader(), lines: lines);
        if (mounted) {
          setState(() {
            _transNo = localId;
            _saving = false;
          });
          _showSnack('Saved offline as $localId — will sync when online.', color: AppColors.secondary);
        }
        return true;
      }

      final savedTransNo = await _ds.save(header: buildHeader(), lines: lines, userId: session.userId);
      await _ds.cacheVoucherLocally(effectiveTransNo: savedTransNo, header: buildHeader()..['trans_no'] = savedTransNo, lines: lines);

      if (mounted) {
        setState(() {
          _transNo = savedTransNo;
          _saving = false;
        });
        _showSnack('Contra Voucher $savedTransNo saved.', color: AppColors.positive);
      }
      return true;
    } catch (e, st) {
      AppLogger.error('ContraVoucherSave', e, st);
      setState(() {
        _saving = false;
        _actionError = ErrorPresenter.format(e, action: 'save the voucher');
      });
      return false;
    }
  }

  Future<void> _approve() async {
    final session = ref.read(sessionProvider)!;
    if (session.offlineMode) {
      if (_transNo == null) {
        final saved = await _saveDraft();
        if (saved && mounted) _showSnack('Saved offline — approval requires an online connection.', color: AppColors.secondary);
      } else {
        _showSnack('Approval requires an online connection.', color: AppColors.negative);
      }
      return;
    }
    if (_transNo == null) {
      final saved = await _saveDraft();
      if (!saved) return;
    }
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Approve Contra Voucher'),
        content: const Text('Once approved, this voucher posts to the General Ledger and can no longer be edited. Continue?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(true), child: const Text('Approve')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _approving = true;
      _actionError = null;
    });
    try {
      await _ds.post(clientId: session.clientId, companyId: session.companyId, locationId: _locationId!, transNo: _transNo!, transDate: _fmtDate(_transDate), postedBy: session.userId);
      if (mounted) {
        _showSnack('Contra Voucher $_transNo approved.', color: AppColors.positive);
        await _init();
      }
    } catch (e, st) {
      AppLogger.error('ContraVoucherApprove', e, st);
      setState(() => _actionError = ErrorPresenter.format(e, action: 'approve the voucher'));
    } finally {
      if (mounted) setState(() => _approving = false);
    }
  }

  void _applyCopy() {
    setState(() {
      _transNo = null;
      _isPosted = false;
      _reversalOfTransNo = null;
      _transDate = DateTime.now();
      _refNoCtrl.clear();
      _refDate = null;
    });
    _showSnack('Copied as a new unsaved draft — Save to assign a new voucher number.', color: AppColors.secondary);
  }

  // Client-side, mirroring _applyCopy() (no server round-trip until the
  // user hits Save/Approve) — replaces the old fn_reverse_voucher RPC call,
  // which flipped Dr/Cr AND posted the reversal atomically in one step, on
  // CURRENT_DATE, with zero chance to review or adjust the date first (real
  // bug reported live 2026-08-17, same fix applied across every voucher
  // screen using this pattern). Reusing _swapFromTo() — reversing a
  // transfer between two accounts genuinely IS swapping From/To, and that
  // method already correctly re-resolves base/local rates for the new From
  // currency. _reversalOfTransNo carries the traceability tag through to
  // buildHeader()'s payload once the user does Save.
  Future<void> _reverse() async {
    if (_transNo == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reverse Contra Voucher'),
        content: const Text(
            'Loads this voucher into a new unsaved draft with From/To swapped. Edit the date, amounts, or remarks as needed, then Save Draft / Approve whenever you\'re ready. Continue?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(false), child: const Text('Cancel')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: AppColors.negative), onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(true), child: const Text('Reverse')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final originalTransNo = _transNo!;
    setState(() {
      _reversalOfTransNo = originalTransNo;
      _transNo = null;
      _isPosted = false;
      _transDate = DateTime.now();
      _refNoCtrl.clear();
      _refDate = null;
      _remarksCtrl.text = 'Reversal of $originalTransNo';
    });
    await _swapFromTo();
    if (mounted) _showSnack('Reversal loaded as a new unsaved draft, From/To swapped — edit as needed, then Save/Approve.', color: AppColors.secondary);
  }

  // ── Print ─────────────────────────────────────────────────────────────

  Map<String, dynamic> _buildPrintDocument(Map<String, dynamic> company) {
    final lines = <Map<String, dynamic>>[
      {'particulars': _fromAccountDisplay, 'amount': _fromAmount, 'party_amount': _fromAmount, 'remarks': 'From'},
      {'particulars': _toAccountDisplay, 'amount': _toTransAmount, 'party_amount': _toAmountEntered, 'remarks': 'To'},
    ];
    if (_showCharge && _chargeAccountId != null) {
      lines.add({'particulars': _chargeAccountDisplay, 'amount': _gap.abs(), 'party_amount': _gap.abs() * _chargePartyRate, 'remarks': 'Transfer Charge'});
    }
    return {
      'company': company,
      'header': {
        'voucher_type_label': _flavorLabel,
        'voucher_no': _transNo ?? '',
        'trans_date': _displayDate(_transDate),
        'currency_line': _fromCurrency,
        'ref_no': _refNoCtrl.text,
        'remarks': _remarksCtrl.text,
      },
      // Top-level, a SIBLING of 'header' — same fix as Journal Voucher's
      // identical bug: the template binds 'signatures.prepared_by' against
      // the document ROOT, not 'header', so nesting it there silently
      // resolved to nothing.
      'signatures': {
        'prepared_by': _preparedByName,
        'authorised_by': _approvedByName,
      },
      'lines': lines,
      'totals': {'total_display': AppNumberFormat.amount(_fromAmount, 'INTERNATIONAL')},
    };
  }

  Future<void> _print() async {
    if (_transNo == null) return;
    setState(() => _printing = true);
    try {
      final company = await ref.read(companyDetailsProvider.future) ?? <String, dynamic>{};
      final template = await ref.read(printTemplateProvider('VOUCHER').future);
      final document = _buildPrintDocument(company);
      final session = ref.read(sessionProvider);
      await PrintEngine.printDocument(
        template: template,
        document: document,
        filename: '$_transNo.pdf',
        printedByName: session?.fullName,
        printedOn: DateTime.now(),
      );
    } catch (e, st) {
      AppLogger.error('ContraVoucherPrint', e, st);
      if (mounted) _showSnack(ErrorPresenter.format(e, action: 'print this voucher'), color: AppColors.negative);
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  String _fmtDate(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _displayDate(DateTime? d) {
    if (d == null) return 'Select date';
    const m = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day.toString().padLeft(2, '0')} ${m[d.month]} ${d.year}';
  }

  String _fmtNum(double n) => n == 0 ? '' : (n.abs() < 1e9 ? _trimZeros(n) : n.toString());
  String _trimZeros(double n) {
    var s = n.toStringAsFixed(4);
    s = s.contains('.') ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '') : s;
    return s;
  }
  String _fmtRate(double n) => n.toString();

  void _showSnack(String msg, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(context: context, initialDate: _transDate, firstDate: DateTime(2020), lastDate: DateTime.now());
    if (d != null) {
      setState(() => _transDate = d);
      await _refreshBaseLocalRates();
      await _refreshFromToRate();
      if (mounted) setState(() {});
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isMobile = Responsive.isMobile(context);
    final canSave = !_locked && (_isNew ? canAdd : canEdit);
    final showApprove = !_locked && canApprove && !_isNew;
    final showReverse = _locked && canApprove;
    final showCopy = !_locked && !_isNew;

    // Title/subtitle/status-badge/Print now live in the shared TopBar via
    // ScreenHeaderMixin — see CLAUDE.md's "Screen header" pattern. Copy/
    // Reverse/Save/Approve stay here as a slim body row (multi-button —
    // never moved into TopBar.actions).
    refreshScreenHeader();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isMobile && (canSave || showApprove || showReverse || showCopy))
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: Wrap(spacing: 8, runSpacing: 8, children: _buildActionButtons(canSave, showApprove, showReverse)),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AppColors.negative))),
                    if (_actionError != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_actionError!, style: const TextStyle(color: AppColors.negative))),
                    _buildHeaderMeta(isMobile),
                    const SizedBox(height: 16),
                    _buildTransferRow(isMobile),
                    const SizedBox(height: 12),
                    _buildChargeSection(),
                    const SizedBox(height: 16),
                    _buildFooterFields(),
                  ]),
                ),
        ),
      ],
    );
  }

  Widget _buildPrintButton() => Tooltip(
    message: _printing ? 'Preparing PDF…' : 'Print',
    child: IconButton(
      icon: _printing
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.print_outlined),
      // sidebarText, not primary — rendered on the dark TopBar now (see
      // the same fix in grn_entry_screen.dart's own _buildPrintButton()).
      color: AppColors.sidebarText,
      onPressed: _printing ? null : _print,
    ),
  );

  List<Widget> _buildActionButtons(bool canSave, bool showApprove, bool showReverse) {
    return [
      if (!_locked && !_isNew) OutlinedButton.icon(onPressed: _applyCopy, icon: const Icon(Icons.copy_outlined, size: 16), label: const Text('Copy')),
      if (showReverse) OutlinedButton.icon(onPressed: _reversing ? null : _reverse, icon: _reversing ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.undo, size: 16), label: const Text('Reverse')),
      if (canSave) FilledButton.icon(onPressed: _saving ? null : () => _saveDraft(), icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save_outlined), label: const Text('Save Draft')),
      if (showApprove) FilledButton.icon(onPressed: _approving ? null : _approve, style: FilledButton.styleFrom(backgroundColor: AppColors.positive), icon: _approving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check_circle_outline), label: const Text('Approve')),
    ];
  }

  Widget _buildHeaderMeta(bool isMobile) {
    final voucherNoField = SakalFieldCard.readOnly(label: 'Voucher No', value: _transNo ?? '—');
    final voucherDateField = InkWell(onTap: !_locked ? _pickDate : null, child: SakalFieldCard.readOnly(label: 'Voucher Date', value: _displayDate(_transDate)));
    final refNoField = SakalFieldCard(label: 'Reference No', editable: !_locked, child: TextFormField(controller: _refNoCtrl, enabled: !_locked, decoration: SakalFieldCard.bareDecoration));
    final refDateField = InkWell(
      onTap: !_locked
          ? () async {
              final d = await showDatePicker(context: context, initialDate: _refDate ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime(2100));
              if (d != null) setState(() => _refDate = d);
            }
          : null,
      child: SakalFieldCard.readOnly(label: 'Reference Date', value: _refDate != null ? _displayDate(_refDate) : '—'),
    );

    // Guard the dropdown's initialValue separately from _locationId itself —
    // a resumed voucher's already-saved location can fall outside the
    // CURRENT user's access grants (e.g. grants changed since, or a
    // different user opens the draft); showing it unselected here is safe
    // (never crashes, never silently mutates _locationId) even though the
    // underlying value is left untouched and still saves correctly.
    final locationInitial = _accessibleLocations.any((l) => l['id'] == _locationId) ? _locationId : null;
    final locationField = SakalFieldCard(
      label: 'Location',
      required: true,
      editable: !_locked,
      child: DropdownButtonFormField<String>(
        initialValue: locationInitial,
        isExpanded: true,
        isDense: true,
        itemHeight: null,
        decoration: SakalFieldCard.bareDecoration,
        items: _accessibleLocations.map((l) => DropdownMenuItem(value: l['id'] as String, child: Text(l['location_name'] as String, overflow: TextOverflow.ellipsis))).toList(),
        onChanged: _locked ? null : (v) => setState(() => _locationId = v),
      ),
    );

    // Rate fields only appear once a cross-currency FROM account is picked
    // — 0, 1, or 2 of them depending on how base/local/from currencies
    // relate, so this row is built dynamically and skipped entirely when
    // empty rather than reserving fixed slots for it.
    final rateFields = <Widget>[
      if (_fromCurrency.isNotEmpty && _fromCurrency != _baseCcy)
        SakalFieldCard(label: '1 $_fromCurrency = ? $_baseCcy', editable: !_locked, numeric: true, child: SakalReciprocalRateField(controller: _baseRateCtrl, enabled: !_locked, onChanged: (_) => setState(() {}))),
      if (_fromCurrency.isNotEmpty && _fromCurrency != _localCcy && _localCcy != _baseCcy)
        SakalFieldCard(label: '1 $_fromCurrency = ? $_localCcy', editable: !_locked, numeric: true, child: SakalReciprocalRateField(controller: _localRateCtrl, enabled: !_locked, onChanged: (_) => setState(() {}))),
    ];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SakalFieldRow(isMobile: isMobile, children: [
        voucherNoField, voucherDateField,
        if (_interLocationModel == 'INTER_ENTITY') locationField,
      ]),
      if (rateFields.isNotEmpty) ...[
        const SizedBox(height: 12),
        SakalFieldRow(isMobile: isMobile, children: rateFields),
      ],
      const SizedBox(height: 12),
      SakalFieldRow(isMobile: isMobile, children: [refNoField, refDateField]),
    ]);
  }

  Widget _buildTransferRow(bool isMobile) {
    final fromBlock = _buildAccountBlock(
      label: 'FROM', required: true,
      accounts: _cashBankAccounts,
      accountDisplay: _fromAccountDisplay,
      focusNode: _fromAccountFocusNode,
      onSelected: _onFromSelected,
      currency: _fromCurrency,
      amountLabel: 'Amount',
      amountCtrl: _fromAmountCtrl,
      amountFocusNode: _fromAmountFocusNode,
      onAmountChanged: _onFromAmountChanged,
      amountSubmitFocus: _toAccountFocusNode,
    );
    final toBlock = _buildAccountBlock(
      label: 'TO', required: true,
      accounts: _cashBankAccounts,
      accountDisplay: _toAccountDisplay,
      focusNode: _toAccountFocusNode,
      onSelected: _onToSelected,
      currency: _toCurrency,
      amountLabel: 'Amount Received',
      amountCtrl: _toAmountCtrl,
      amountFocusNode: _toAmountFocusNode,
      onAmountChanged: _onToAmountChanged,
      amountSubmitFocus: _remarksFocusNode,
    );

    if (isMobile) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        fromBlock,
        Center(child: IconButton(onPressed: !_locked ? _swapFromTo : null, icon: const Icon(Icons.swap_vert), tooltip: 'Swap From/To', color: AppColors.primary)),
        toBlock,
      ]);
    }
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(child: fromBlock),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: IconButton(onPressed: !_locked ? _swapFromTo : null, icon: const Icon(Icons.swap_horiz), tooltip: 'Swap From/To', color: AppColors.primary),
        ),
        Expanded(child: toBlock),
      ]),
    );
  }

  Widget _buildAccountBlock({
    required String label,
    required bool required,
    required List<Map<String, dynamic>> accounts,
    required String accountDisplay,
    required FocusNode focusNode,
    required ValueChanged<Map<String, dynamic>> onSelected,
    required String currency,
    required String amountLabel,
    required TextEditingController amountCtrl,
    required FocusNode amountFocusNode,
    required ValueChanged<String> onAmountChanged,
    required FocusNode amountSubmitFocus,
  }) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: AppColors.textSecondary)),
          const SizedBox(height: 8),
          SakalFieldCard(
            label: 'Account',
            required: required,
            editable: !_locked,
            // key: ValueKey(accountDisplay) — SakalAutocomplete only reads
            // its initialValue once at first mount (documented gotcha);
            // without a changing key, a programmatic swap wouldn't visually
            // resync the field text. Same fix GRN's own picker already
            // uses (key: ValueKey(initialText)).
            child: FinanceAccountPicker(
              key: ValueKey(accountDisplay),
              accounts: accounts,
              initialValue: accountDisplay.isEmpty ? null : accountDisplay,
              enabled: !_locked,
              focusNode: focusNode,
              decoration: SakalFieldCard.bareDecoration,
              onSelected: onSelected,
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            SizedBox(width: 90, child: SakalFieldCard.readOnly(label: 'Currency', value: currency.isEmpty ? '—' : currency)),
            const SizedBox(width: 8),
            Expanded(
              child: SakalFieldCard(
                label: amountLabel,
                editable: !_locked,
                numeric: true,
                child: TextFormField(
                  controller: amountCtrl,
                  focusNode: amountFocusNode,
                  enabled: !_locked,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,4}'))],
                  decoration: SakalFieldCard.bareDecoration,
                  textAlign: TextAlign.right,
                  onChanged: onAmountChanged,
                  textInputAction: TextInputAction.next,
                  onFieldSubmitted: (_) => amountSubmitFocus.requestFocus(),
                ),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _buildChargeSection() {
    if (!_showCharge) {
      return _locked
          ? const SizedBox.shrink()
          : TextButton.icon(
              onPressed: _addChargeManually,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add Transfer Charge (bank fee, courier charge, etc.)'),
            );
    }
    final gapLabel = _gapExists ? (_gap > 0 ? 'Transfer Charge' : 'Exchange Gain') : 'Transfer Charge';
    return Card(
      elevation: 0,
      color: AppColors.background,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(gapLabel, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textSecondary))),
            if (!_locked) IconButton(icon: const Icon(Icons.close, size: 16, color: AppColors.negative), onPressed: _removeCharge, tooltip: 'Remove', padding: EdgeInsets.zero, constraints: const BoxConstraints()),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 12, runSpacing: 8, children: [
            SizedBox(
              width: 320,
              child: SakalFieldCard(
                label: 'Charge Account',
                required: true,
                editable: !_locked,
                child: FinanceAccountPicker(
                  key: ValueKey(_chargeAccountDisplay),
                  accounts: _chargeAccounts,
                  initialValue: _chargeAccountDisplay.isEmpty ? null : _chargeAccountDisplay,
                  enabled: !_locked,
                  decoration: SakalFieldCard.bareDecoration,
                  onSelected: _onChargeSelected,
                ),
              ),
            ),
            SizedBox(
              width: 150,
              child: SakalFieldCard(
                label: 'Amount', editable: !_locked, numeric: true,
                child: TextFormField(
                  controller: _chargeAmountCtrl,
                  enabled: !_locked,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,4}'))],
                  decoration: SakalFieldCard.bareDecoration,
                  textAlign: TextAlign.right,
                  onChanged: (_) { _chargeAmountManuallyEdited = true; setState(() {}); },
                ),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _buildFooterFields() {
    return SakalFieldCard(
      label: 'Remarks',
      editable: !_locked,
      child: TextFormField(
        controller: _remarksCtrl,
        focusNode: _remarksFocusNode,
        enabled: !_locked,
        decoration: SakalFieldCard.bareDecoration,
        textInputAction: TextInputAction.done,
        onFieldSubmitted: (_) { if (!_saving) _saveDraft(); },
      ),
    );
  }
}
