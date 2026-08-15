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
import '../../../../core/theme/theme_presets.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../core/utils/app_number_format.dart';
import '../../../../core/utils/deferred_row_disposal.dart';
import '../../../../core/utils/local_id.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/sakal_field_card.dart';
import '../../../../core/widgets/sakal_field_row.dart';
import '../../../../core/widgets/sakal_scrollable_table.dart';
import '../../../../core/widgets/sakal_table_header_bar.dart';
import '../../../../core/widgets/sakal_header_action_button.dart';
import '../../../../core/widgets/sakal_reciprocal_rate_field.dart';
import '../../../../core/printing/print_engine.dart';
import '../../../../core/printing/print_template_provider.dart';
import '../../domain/repositories/finance_voucher_repository.dart';
import '../providers/finance_voucher_providers.dart';
import '../widgets/finance_account_picker.dart';

/// One free-form Dr/Cr account line. Unlike Payment/Receipt Voucher (a
/// fixed Cash/Bank line 1 + one uniform nature for every other line),
/// every JV line independently picks its own account and its own Dr/Cr
/// side — see docs/screens/journal_voucher.md for why this couldn't
/// reuse the existing screen's On-Account mode.
class _JVLineRow implements DisposableRow {
  String? accountId;
  String accountDisplay = '';
  String accountNature = '';
  String parentName = '';
  String accountCurrency = '';
  String natureDrCr = 'DR';
  double partyRate = 1;

  // Plan §7 — the reverse-direction complementary feature: entirely the
  // user's own choice, never forced. Only meaningful for a line that
  // credits a Customer or debits a Supplier.
  bool settleAgainstBill = false;
  Map<String, dynamic>? selectedBill; // a v_pending_bills row

  final TextEditingController amountCtrl = TextEditingController();
  final TextEditingController remarksCtrl = TextEditingController();
  final FocusNode accountFocusNode = FocusNode();
  final FocusNode amountFocusNode = FocusNode();
  final FocusNode addButtonFocusNode = FocusNode();

  double get amount => double.tryParse(amountCtrl.text) ?? 0;

  /// Plan §7's main rule — automatic, unambiguous: a customer debit is
  /// always a new receivable, a supplier credit is always a new payable.
  bool get autoCreatesBill =>
      (accountNature == 'Customer' && natureDrCr == 'DR') || (accountNature == 'Supplier' && natureDrCr == 'CR');

  /// The reverse directions — where the opt-in settlement picker applies.
  bool get canOptIntoSettlement =>
      (accountNature == 'Customer' && natureDrCr == 'CR') || (accountNature == 'Supplier' && natureDrCr == 'DR');

  @override
  void dispose() {
    amountCtrl.dispose();
    remarksCtrl.dispose();
    accountFocusNode.dispose();
    amountFocusNode.dispose();
    addButtonFocusNode.dispose();
  }
}

class JournalVoucherEntryScreen extends ConsumerStatefulWidget {
  final String? editTransNo;
  final String? editTransDate;
  const JournalVoucherEntryScreen({super.key, this.editTransNo, this.editTransDate});

  @override
  ConsumerState<JournalVoucherEntryScreen> createState() => _JournalVoucherEntryScreenState();
}

class _JournalVoucherEntryScreenState extends ConsumerState<JournalVoucherEntryScreen>
    with ScreenPermissionMixin<JournalVoucherEntryScreen>, ScreenHeaderMixin<JournalVoucherEntryScreen>, DeferredRowDisposal<JournalVoucherEntryScreen> {
  @override
  String get screenName => RouteNames.journalEntry;

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
      title: _transNo ?? 'New Journal Voucher',
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
  String? _locationId;
  // Location picker only matters (and only renders) under INTER_ENTITY
  // accounting — see CLAUDE.md's "Inter-Location Model". Under SIMPLE
  // (the default) these stay at their defaults and nothing changes.
  String _interLocationModel = 'SIMPLE';
  List<Map<String, dynamic>> _accessibleLocations = const [];

  String _baseCcy = '';
  String _localCcy = '';
  List<Map<String, dynamic>> _currencies = [];
  String? _currencyId; // rim_currencies.id
  String _currencyCode = ''; // rim_currencies.currency_id (ISO code)
  final _baseRateCtrl = TextEditingController(text: '1');
  final _localRateCtrl = TextEditingController(text: '1');

  final _refNoCtrl = TextEditingController();
  DateTime? _refDate;
  final _remarksCtrl = TextEditingController();

  // Keyboard-chaining focus nodes — see the header field flow: screen
  // opens focused on Currency (not the first line's Account field, which
  // would otherwise immediately pop open FinanceAccountPicker's own
  // desktop dialog on load); Currency -> Reference No; Reference Date ->
  // Remarks (no FocusNode needed there, it's a tap-to-open date picker,
  // not a real keyboard field).
  final _currencyFocusNode = FocusNode();
  final _refNoFocusNode = FocusNode();
  final _remarksFocusNode = FocusNode();

  // All postable accounts (Customer/Supplier included even if not
  // posting_allowed) — the SAME shared cache Payment/Receipt Voucher and
  // Purchase Order use. Cash/Bank is filtered out client-side, only for
  // this screen's own picker instance — the shared cache itself is
  // untouched (other screens still need Cash/Bank in it).
  List<Map<String, dynamic>> _allAccounts = [];
  List<Map<String, dynamic>> get _pickableAccounts =>
      _allAccounts.where((a) => a['account_nature'] != 'Cash' && a['account_nature'] != 'Bank' && a['posting_allowed'] == true).toList();

  final List<_JVLineRow> _lines = [];

  bool _loading = true;
  String? _error;
  String? _actionError;
  bool _saving = false;
  bool _approving = false;
  bool _reversing = false;
  bool _printing = false;

  // FinanceVoucherHeader already resolves these via its own SQL join
  // (created_by_user/posted_by_user) — no separate user lookup needed.
  String _preparedByName = '';
  String _approvedByName = '';

  bool get _isNew => _transNo == null;
  bool get _locked => _isPosted;

  double get _totalDr => _lines.where((l) => l.natureDrCr == 'DR').fold(0.0, (s, l) => s + l.amount);
  double get _totalCr => _lines.where((l) => l.natureDrCr == 'CR').fold(0.0, (s, l) => s + l.amount);
  bool get _isBalanced => (_totalDr - _totalCr).abs() < 0.01 && _totalDr > 0;

  @override
  void initState() {
    super.initState();
    _addLine(focusAccount: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _currencyFocusNode.requestFocus();
      _init();
    });
  }

  @override
  void dispose() {
    _baseRateCtrl.dispose();
    _localRateCtrl.dispose();
    _refNoCtrl.dispose();
    _remarksCtrl.dispose();
    _currencyFocusNode.dispose();
    _refNoFocusNode.dispose();
    _remarksFocusNode.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    disposeDeferredRows();
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
      _currencies = await ref.read(currenciesProvider.future);
      _allAccounts = await ref.read(accountsProvider.future);

      // widget.editTransNo only covers "opened to edit an existing voucher"
      // — a freshly-created-then-saved-then-approved voucher (same screen
      // instance) has its trans_no in _transNo instead; re-reading only
      // widget.editTransNo (a constructor param, can't be mutated) silently
      // skips this reload on every subsequent _init() call, so the
      // post-approve status never made it back onto the screen. Same fix as
      // Expense Voucher's identical bug — see that screen's own comment.
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
          if (lines.isNotEmpty) {
            _currencyCode = lines.first.transCurrency;
            final match = _currencies.firstWhere((c) => c['currency_id'] == _currencyCode, orElse: () => const {});
            _currencyId = match['id'] as String?;
            _baseRateCtrl.text = _fmtRate(lines.first.baseRate);
            _localRateCtrl.text = _fmtRate(lines.first.localRate);

            for (final l in _lines) {
              l.dispose();
            }
            _lines.clear();
            for (final l in lines) {
              final row = _JVLineRow();
              final account = _allAccounts.firstWhere((a) => a['id'] == l.accountId, orElse: () => const {});
              row.accountId = l.accountId;
              row.accountDisplay = account.isNotEmpty ? FinanceAccountPicker.displayString(account) : '';
              row.accountNature = account['account_nature'] as String? ?? '';
              row.parentName = (account['parent'] as Map<String, dynamic>?)?['account_name'] as String? ?? '';
              row.accountCurrency = (account['rim_currencies'] as Map<String, dynamic>?)?['currency_id'] as String? ?? '';
              row.natureDrCr = l.transNature;
              row.amountCtrl.text = _fmtNum(l.transAmount);
              row.remarksCtrl.text = l.lineRemarks;
              row.partyRate = l.partyRate;
              if (l.invBillNo.isNotEmpty && !row.autoCreatesBill) {
                row.settleAgainstBill = true;
                row.selectedBill = {'trans_no': l.invBillNo, 'trans_date': l.invBillDate, 'account_id': l.accountId};
              }
              _lines.add(row);
            }
          }
          _preparedByName = header.createdByName;
          _approvedByName = header.postedByName;
        }
      }

      if (mounted) setState(() => _loading = false);
    } catch (e, st) {
      AppLogger.error('JournalVoucherLoad', e, st);
      if (mounted) {
        setState(() {
          _loading = false;
          _error = ErrorPresenter.format(e, action: 'load this voucher');
        });
      }
    }
  }

  // ── Currency / rate handling ────────────────────────────────────────

  Future<void> _onCurrencySelected(Map<String, dynamic> currency) async {
    setState(() {
      _currencyId = currency['id'] as String?;
      _currencyCode = currency['currency_id'] as String? ?? '';
    });
    await _resolveRates();
    // The trans currency changed — every line's own "other-currency"
    // cross-rate (fetched trans→partyCcy) is now stale and must be
    // re-fetched. Base/local-currency parties don't need this: they
    // read the header rate live via _partyRateFor, never a cached fetch.
    for (final l in _lines) {
      await _refreshLinePartyRate(l);
    }
    if (mounted) setState(() {});
  }

  Future<void> _resolveRates() async {
    if (_currencyCode.isEmpty || _locationId == null) return;
    final session = ref.read(sessionProvider)!;
    if (_currencyCode == _baseCcy) {
      _baseRateCtrl.text = '1';
    } else {
      final r = await _ds.fetchExchangeRate(companyId: session.companyId, locationId: _locationId!, fromCurrency: _currencyCode, toCurrency: _baseCcy, rateDate: _fmtDate(_transDate));
      _baseRateCtrl.text = _fmtRate(r ?? 1);
    }
    if (_currencyCode == _localCcy) {
      _localRateCtrl.text = '1';
    } else {
      final r = await _ds.fetchExchangeRate(companyId: session.companyId, locationId: _locationId!, fromCurrency: _currencyCode, toCurrency: _localCcy, rateDate: _fmtDate(_transDate));
      _localRateCtrl.text = _fmtRate(r ?? 1);
    }
    if (mounted) setState(() {});
  }

  double get _baseRate => double.tryParse(_baseRateCtrl.text) ?? 1;
  double get _localRate => double.tryParse(_localRateCtrl.text) ?? 1;

  // ── Lines ────────────────────────────────────────────────────────────

  void _addLine({bool focusAccount = true}) {
    final row = _JVLineRow();
    // New lines pick up whatever's currently in the header Remarks field
    // as a starting point — user can still edit/clear it per line. Not
    // applied retroactively to already-existing lines.
    row.remarksCtrl.text = _remarksCtrl.text;
    setState(() => _lines.add(row));
    if (!focusAccount) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) row.accountFocusNode.requestFocus();
    });
  }

  void _removeLine(_JVLineRow row) {
    setState(() {
      _lines.remove(row);
      if (_lines.isEmpty) _lines.add(_JVLineRow());
    });
    // Never dispose a just-removed row's controllers/FocusNodes inside the
    // same setState that removes it from the tree — see DeferredRowDisposal.
    deferRowDisposal(row);
  }

  Future<void> _onAccountSelected(_JVLineRow row, Map<String, dynamic> account) async {
    setState(() {
      row.accountId = account['id'] as String?;
      row.accountDisplay = FinanceAccountPicker.displayString(account);
      row.accountNature = account['account_nature'] as String? ?? '';
      row.parentName = (account['parent'] as Map<String, dynamic>?)?['account_name'] as String? ?? '';
      row.accountCurrency = (account['rim_currencies'] as Map<String, dynamic>?)?['currency_id'] as String? ?? '';
      row.settleAgainstBill = false;
      row.selectedBill = null;
    });
    await _refreshLinePartyRate(row);
    if (mounted) setState(() {});
    row.amountFocusNode.requestFocus();
  }

  /// Fetches a fresh cross-rate ONLY for a party currency that is
  /// genuinely a fourth currency (not trans/base/local — those three
  /// are read live via [_partyRateFor], always reusing the header's own,
  /// possibly user-edited rate rather than a stale independent lookup —
  /// same fix already applied to GRN's own party-rate resolution (052/053)).
  Future<void> _refreshLinePartyRate(_JVLineRow row) async {
    if (row.accountCurrency.isEmpty ||
        row.accountCurrency == _currencyCode ||
        row.accountCurrency == _baseCcy ||
        row.accountCurrency == _localCcy ||
        _locationId == null) {
      return;
    }
    final session = ref.read(sessionProvider)!;
    final r = await _ds.fetchExchangeRate(companyId: session.companyId, locationId: _locationId!, fromCurrency: _currencyCode, toCurrency: row.accountCurrency, rateDate: _fmtDate(_transDate));
    row.partyRate = r ?? 1;
  }

  /// Party Amount rule (plan spec): party currency == base ⇒ equals base
  /// amount; == local ⇒ equals local amount; otherwise the row's own
  /// fetched cross-rate. Computed live off the header's current
  /// (possibly user-edited) rate fields, never a frozen snapshot — so
  /// editing the reciprocal-rate field after picking an account still
  /// updates Party Amount correctly with zero extra plumbing.
  double _partyRateFor(_JVLineRow row) {
    if (row.accountCurrency.isEmpty || row.accountCurrency == _currencyCode) return 1;
    if (row.accountCurrency == _baseCcy) return _baseRate;
    if (row.accountCurrency == _localCcy) return _localRate;
    return row.partyRate;
  }

  Future<void> _pickSettlementBill(_JVLineRow row) async {
    if (row.accountId == null || _locationId == null) return;
    final session = ref.read(sessionProvider)!;
    List<Map<String, dynamic>> bills;
    try {
      bills = await _ds.getPendingBills(companyId: session.companyId, locationId: _locationId!, accountId: row.accountId!);
    } catch (e, st) {
      AppLogger.error('JournalVoucherPendingBills', e, st);
      _showSnack(ErrorPresenter.format(e, action: 'load pending bills'), color: AppColors.negative);
      return;
    }
    if (!mounted) return;
    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Settle Against Bill'),
        content: SizedBox(
          width: 420,
          child: bills.isEmpty
              ? const Text('No pending bills for this account.')
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: bills.length,
                  itemBuilder: (context, i) {
                    final b = bills[i];
                    return ListTile(
                      dense: true,
                      title: Text('${b['inv_bill_no']} (${b['inv_bill_date']})'),
                      subtitle: Text('Balance: ${AppNumberFormat.amount((b['balance_amount'] as num? ?? 0).toDouble(), 'INTERNATIONAL')} ${b['party_currency']}'),
                      onTap: () => Navigator.of(dialogContext, rootNavigator: true).pop(b),
                    );
                  },
                ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(), child: const Text('Cancel'))],
      ),
    );
    if (picked != null) {
      setState(() {
        row.selectedBill = {'trans_no': picked['trans_no'], 'trans_date': picked['trans_date'], 'account_id': row.accountId};
      });
    }
  }

  // ── Save / Approve / Copy / Reverse ─────────────────────────────────

  /// Plan §7's edge case: at most one auto-tagged line per customer (or
  /// supplier) per JV — they'd collide on (account_id, inv_bill_no).
  String? _validateBillCollisions() {
    final seen = <String>{};
    for (final l in _lines) {
      if (!l.autoCreatesBill || l.accountId == null) continue;
      if (!seen.add(l.accountId!)) {
        return 'This voucher debits/credits the same customer or supplier on more than one line — combine them into a single line before saving.';
      }
    }
    return null;
  }

  Future<bool> _saveDraft() async {
    if (_currencyId == null) {
      _showSnack('Select a currency.', color: AppColors.negative);
      return false;
    }
    if (_interLocationModel == 'INTER_ENTITY' && _locationId == null) {
      _showSnack('Select a location.', color: AppColors.negative);
      return false;
    }
    final validLines = _lines.where((l) => l.accountId != null && l.amount > 0).toList();
    if (validLines.length < 2) {
      _showSnack('Add at least two lines.', color: AppColors.negative);
      return false;
    }
    if (!_isBalanced) {
      _showSnack('Debit and Credit totals must match before saving.', color: AppColors.negative);
      return false;
    }
    final collisionError = _validateBillCollisions();
    if (collisionError != null) {
      _showSnack(collisionError, color: AppColors.negative);
      return false;
    }

    setState(() {
      _saving = true;
      _actionError = null;
    });
    final session = ref.read(sessionProvider)!;
    try {
      final refNo = _refNoCtrl.text.trim();
      final refDate = _refDate != null ? _fmtDate(_refDate!) : '';
      final hasRefFallback = refNo.isNotEmpty && refDate.isNotEmpty;

      Map<String, dynamic> buildHeader() => {
            'client_id': session.clientId,
            'company_id': session.companyId,
            'location_id': _locationId,
            'trans_no': _transNo ?? '',
            'trans_date': _fmtDate(_transDate),
            'voucher_type_code': 'JV',
            'is_on_account': true,
            'reference_no': refNo,
            'reference_date': refDate,
            'remarks': _remarksCtrl.text.trim(),
          };

      Map<String, dynamic> buildLine(_JVLineRow l, int serial, {String? billNo, String? billDate}) => {
            'serial_no': serial,
            'account_id': l.accountId,
            'trans_nature': l.natureDrCr,
            'trans_amount': l.amount,
            'trans_currency': _currencyCode,
            'base_amount': l.amount * _baseRate,
            'base_rate': _baseRate,
            'local_amount': l.amount * _localRate,
            'local_rate': _localRate,
            'party_amount': l.amount * _partyRateFor(l),
            'party_currency': l.accountCurrency.isEmpty ? _currencyCode : l.accountCurrency,
            'party_rate': _partyRateFor(l),
            'inv_bill_no': billNo ?? '',
            'inv_bill_date': billDate ?? '',
            'line_remarks': l.remarksCtrl.text.trim(),
          };

      // Lines needing the fallback (auto-creates a bill, no ref no/date
      // supplied) can't know their own voucher_no until after the first
      // save — same self-reference problem Sales Invoice's own Customer
      // DR line has, solved here as two saves instead of a raw UPDATE,
      // since this logic lives in Flutter, not a dedicated PG function.
      final needsFallback = validLines.where((l) => l.autoCreatesBill && !hasRefFallback).toList();

      if (session.offlineMode) {
        // Offline: no two-pass fix-up possible (trans_no isn't known
        // until the queued save actually syncs). A bill-creating line
        // without ref no/date just saves without inv_bill_no this once —
        // documented, low-risk, matches this app's other offline
        // limitations (re-openable and re-saveable once online).
        final lines = validLines.asMap().entries.map((e) {
          final l = e.value;
          String? billNo, billDate;
          if (l.autoCreatesBill && hasRefFallback) {
            billNo = refNo;
            billDate = refDate;
          } else if (l.canOptIntoSettlement && l.settleAgainstBill && l.selectedBill != null) {
            billNo = l.selectedBill!['trans_no'] as String?;
            billDate = l.selectedBill!['trans_date'] as String?;
          }
          return buildLine(l, e.key + 1, billNo: billNo, billDate: billDate);
        }).toList();

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

      final firstPassLines = validLines.asMap().entries.map((e) {
        final l = e.value;
        String? billNo, billDate;
        if (l.autoCreatesBill && hasRefFallback) {
          billNo = refNo;
          billDate = refDate;
        } else if (l.canOptIntoSettlement && l.settleAgainstBill && l.selectedBill != null) {
          billNo = l.selectedBill!['trans_no'] as String?;
          billDate = l.selectedBill!['trans_date'] as String?;
        }
        return buildLine(l, e.key + 1, billNo: billNo, billDate: billDate);
      }).toList();

      final savedTransNo = await _ds.save(header: buildHeader(), lines: firstPassLines, userId: session.userId);

      if (needsFallback.isNotEmpty) {
        final secondPassLines = validLines.asMap().entries.map((e) {
          final l = e.value;
          String? billNo, billDate;
          if (l.autoCreatesBill) {
            if (hasRefFallback) {
              billNo = refNo;
              billDate = refDate;
            } else {
              billNo = savedTransNo;
              billDate = _fmtDate(_transDate);
            }
          } else if (l.canOptIntoSettlement && l.settleAgainstBill && l.selectedBill != null) {
            billNo = l.selectedBill!['trans_no'] as String?;
            billDate = l.selectedBill!['trans_date'] as String?;
          }
          return buildLine(l, e.key + 1, billNo: billNo, billDate: billDate);
        }).toList();
        final headerForEdit = buildHeader()..['trans_no'] = savedTransNo;
        await _ds.save(header: headerForEdit, lines: secondPassLines, userId: session.userId);
      }

      await _ds.cacheVoucherLocally(effectiveTransNo: savedTransNo, header: buildHeader()..['trans_no'] = savedTransNo, lines: firstPassLines);

      if (mounted) {
        setState(() {
          _transNo = savedTransNo;
          _saving = false;
        });
        _showSnack('Journal Voucher $savedTransNo saved.', color: AppColors.positive);
      }
      return true;
    } catch (e, st) {
      AppLogger.error('JournalVoucherSave', e, st);
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
        title: const Text('Approve Journal Voucher'),
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
        _showSnack('Journal Voucher $_transNo approved.', color: AppColors.positive);
        await _init();
      }
    } catch (e, st) {
      AppLogger.error('JournalVoucherApprove', e, st);
      setState(() => _actionError = ErrorPresenter.format(e, action: 'approve the voucher'));
    } finally {
      if (mounted) setState(() => _approving = false);
    }
  }

  void _applyCopy() {
    setState(() {
      _transNo = null;
      _isPosted = false;
      _transDate = DateTime.now();
      _refNoCtrl.clear();
      _refDate = null;
    });
    _showSnack('Copied as a new unsaved draft — Save to assign a new voucher number.', color: AppColors.secondary);
  }

  Future<void> _reverse() async {
    if (_transNo == null) return;
    final session = ref.read(sessionProvider)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reverse Journal Voucher'),
        content: const Text('This posts a new voucher with every line\'s Debit/Credit flipped, exactly mirroring this one. Continue?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(false), child: const Text('Cancel')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: AppColors.negative), onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(true), child: const Text('Reverse')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _reversing = true;
      _actionError = null;
    });
    try {
      final res = await ref.read(financeVoucherRepositoryProvider).reverseVoucher(
            clientId: session.clientId,
            companyId: session.companyId,
            transNo: _transNo!,
            transDate: _fmtDate(_transDate),
            userId: session.userId,
          );
      if (mounted) _showSnack('Reversal voucher $res posted.', color: AppColors.positive);
    } catch (e, st) {
      AppLogger.error('JournalVoucherReverse', e, st);
      setState(() => _actionError = ErrorPresenter.format(e, action: 'reverse the voucher'));
    } finally {
      if (mounted) setState(() => _reversing = false);
    }
  }

  // ── Print ─────────────────────────────────────────────────────────────

  Map<String, dynamic> _buildPrintDocument(Map<String, dynamic> company) {
    return {
      'company': company,
      'header': {
        'voucher_type_label': 'Journal Voucher',
        'voucher_no': _transNo ?? '',
        'trans_date': _displayDate(_transDate),
        'currency_line': _currencyCode,
        'ref_no': _refNoCtrl.text,
        'remarks': _remarksCtrl.text,
        'signatures': {
          'prepared_by': _preparedByName,
          'authorised_by': _approvedByName,
        },
      },
      'lines': _lines.where((l) => l.amount > 0).map((l) => {
            'particulars': l.accountDisplay,
            'amount': l.amount,
            'party_amount': l.amount * _partyRateFor(l),
            'remarks': l.remarksCtrl.text,
          }).toList(),
      'totals': {'total_display': AppNumberFormat.amount(_totalDr, 'INTERNATIONAL')},
    };
  }

  Future<void> _print() async {
    if (_transNo == null) return;
    setState(() => _printing = true);
    try {
      final company = await ref.read(companyDetailsProvider.future) ?? <String, dynamic>{};
      final template = await ref.read(printTemplateProvider('VOUCHER').future);
      final document = _buildPrintDocument(company);
      await PrintEngine.printDocument(template: template, document: document, filename: '$_transNo.pdf');
    } catch (e, st) {
      AppLogger.error('JournalVoucherPrint', e, st);
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

  String _fmtNum(double n) => n == 0 ? '' : n.toString();
  String _fmtRate(double n) => n.toString();

  void _showSnack(String msg, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(context: context, initialDate: _transDate, firstDate: DateTime(2020), lastDate: DateTime.now());
    if (d != null) {
      setState(() => _transDate = d);
      await _resolveRates();
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
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AppColors.negative))),
                    if (_actionError != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_actionError!, style: const TextStyle(color: AppColors.negative))),
                    _buildHeaderSection(isMobile),
                    const SizedBox(height: 20),
                    _buildLinesSection(isMobile),
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

  Widget _buildHeaderSection(bool isMobile) {
    final voucherNoField = SakalFieldCard.readOnly(label: 'Voucher No', value: _transNo ?? '—');
    final voucherDateField = InkWell(onTap: !_locked ? _pickDate : null, child: SakalFieldCard.readOnly(label: 'Voucher Date', value: _displayDate(_transDate)));
    final currencyField = SakalFieldCard(
      label: 'Currency',
      required: true,
      editable: !_locked,
      child: DropdownButtonFormField<String>(
        initialValue: _currencyId,
        focusNode: _currencyFocusNode,
        isExpanded: true,
        isDense: true,
        itemHeight: null,
        decoration: SakalFieldCard.bareDecoration,
        style: SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider)),
        items: _currencies.map((c) => DropdownMenuItem(value: c['id'] as String, child: Text(c['currency_id'] as String))).toList(),
        onChanged: _locked
            ? null
            : (v) async {
                final match = _currencies.firstWhere((c) => c['id'] == v, orElse: () => const {});
                // Awaited BEFORE moving focus — _onCurrencySelected does
                // several awaits + setState calls of its own (rate
                // lookups), each rebuilding this section; requesting focus
                // on Reference No BEFORE that churn settles let a
                // still-in-flight rebuild detach the just-focused field's
                // real text-input connection, landing focus on Remarks
                // instead (Flutter's own next-best-target fallback) with a
                // visible focus ring but no working keyboard input until a
                // real click re-opened it (found live 2026-08-16).
                if (match.isNotEmpty) await _onCurrencySelected(match);
                if (mounted) _refNoFocusNode.requestFocus();
              },
      ),
    );
    final refNoField = SakalFieldCard(
      label: 'Reference No',
      editable: !_locked,
      child: TextFormField(controller: _refNoCtrl, focusNode: _refNoFocusNode, enabled: !_locked, decoration: SakalFieldCard.bareDecoration),
    );
    final refDateField = InkWell(
      onTap: !_locked
          ? () async {
              final d = await showDatePicker(context: context, initialDate: _refDate ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime(2100));
              if (d != null) {
                setState(() => _refDate = d);
                _remarksFocusNode.requestFocus();
              }
            }
          : null,
      child: SakalFieldCard.readOnly(label: 'Reference Date', value: _refDate != null ? _displayDate(_refDate) : '—'),
    );
    final remarksField = SakalFieldCard(
      label: 'Remarks',
      editable: !_locked,
      child: TextFormField(
        controller: _remarksCtrl,
        focusNode: _remarksFocusNode,
        enabled: !_locked,
        decoration: SakalFieldCard.bareDecoration,
        // Live-propagates to any line whose own Remarks is still empty —
        // covers BOTH directions: a line added before the user gets to
        // Header Remarks (the common case — the first line is auto-added
        // on screen open, before this field has anything in it, so
        // _addLine's own "seed from current header text" never applied to
        // it) and a line added after. Never overwrites a line the user has
        // already typed something into. Found live 2026-08-16 — the
        // one-time copy-at-creation alone missed the single-line-JV case,
        // by far the most common one.
        onChanged: (v) => setState(() {
          for (final l in _lines) {
            if (l.remarksCtrl.text.isEmpty) l.remarksCtrl.text = v;
          }
        }),
      ),
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
        style: SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider)),
        items: _accessibleLocations.map((l) => DropdownMenuItem(value: l['id'] as String, child: Text(l['location_name'] as String, overflow: TextOverflow.ellipsis))).toList(),
        onChanged: _locked ? null : (v) => setState(() => _locationId = v),
      ),
    );

    // Rate fields only appear once a cross-currency voucher currency is
    // picked — 0, 1, or 2 of them depending on how base/local/voucher
    // currencies relate, so this row is built dynamically and skipped
    // entirely when empty rather than reserving fixed slots for it.
    final rateFields = <Widget>[
      if (_currencyCode.isNotEmpty && _currencyCode != _baseCcy)
        SakalFieldCard(label: '1 $_currencyCode = ? $_baseCcy', editable: !_locked, numeric: true, child: SakalReciprocalRateField(controller: _baseRateCtrl, enabled: !_locked, onChanged: (_) => setState(() {}))),
      if (_currencyCode.isNotEmpty && _currencyCode != _localCcy && _localCcy != _baseCcy)
        SakalFieldCard(label: '1 $_currencyCode = ? $_localCcy', editable: !_locked, numeric: true, child: SakalReciprocalRateField(controller: _localRateCtrl, enabled: !_locked, onChanged: (_) => setState(() {}))),
    ];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SakalFieldRow(isMobile: isMobile, spacing: 24, children: [
        voucherNoField, voucherDateField, currencyField,
        if (_interLocationModel == 'INTER_ENTITY') locationField,
      ]),
      if (rateFields.isNotEmpty) ...[
        const SizedBox(height: 12),
        SakalFieldRow(isMobile: isMobile, children: rateFields),
      ],
      const SizedBox(height: 12),
      SakalFieldRow(isMobile: isMobile, children: [refNoField, refDateField]),
      const SizedBox(height: 12),
      SakalFieldRow(isMobile: isMobile, children: [remarksField]),
    ]);
  }

  Widget _buildLinesSection(bool isMobile) {
    // Desktop: one continuous horizontally-scrollable row per line under a
    // dark SakalTableHeaderBar, instead of a Wrap that pushed fields onto a
    // second line once the row's fixed column widths (~1340px) exceeded
    // the viewport — see CLAUDE.md's "Line-items grid" mandatory pattern,
    // same shape as Purchase Order's own product list. Mobile keeps the
    // existing Wrap-based card (not the full SakalLineItemCard migration —
    // out of scope for this fix, which is specifically about desktop
    // wrapping).
    final lineWidgets = [for (var i = 0; i < _lines.length; i++) _buildLineCard(_lines[i], i, isMobile)];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Expanded(child: Text('Account Lines', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
        Text(
          'Dr ${AppNumberFormat.amount(_totalDr, 'INTERNATIONAL')}  /  Cr ${AppNumberFormat.amount(_totalCr, 'INTERNATIONAL')}',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _isBalanced ? AppColors.positive : AppColors.negative),
        ),
      ]),
      const SizedBox(height: 8),
      if (isMobile)
        ...lineWidgets
      else
        SakalScrollableTable(header: _buildLinesHeader(), rows: lineWidgets),
    ]);
  }

  // Same left-to-right column order/widths as _buildLineCard's own desktop
  // Row below, so the header stays pixel-aligned with the data.
  Widget _buildLinesHeader() {
    return SakalTableHeaderBar(cells: [
      SizedBox(width: 320, child: SakalTableHeaderBar.label('Account')),
      const SizedBox(width: 8),
      SizedBox(width: 150, child: SakalTableHeaderBar.label('Parent Group')),
      const SizedBox(width: 8),
      SizedBox(width: 90, child: SakalTableHeaderBar.label('Currency')),
      const SizedBox(width: 8),
      SizedBox(width: 130, child: SakalTableHeaderBar.label('Amount')),
      const SizedBox(width: 8),
      SizedBox(width: 90, child: SakalTableHeaderBar.label('Dr / Cr')),
      const SizedBox(width: 8),
      SizedBox(width: 120, child: SakalTableHeaderBar.label('Base Amount')),
      const SizedBox(width: 8),
      SizedBox(width: 120, child: SakalTableHeaderBar.label('Local Amount')),
      const SizedBox(width: 8),
      SizedBox(width: 120, child: SakalTableHeaderBar.label('Party Amount')),
      const SizedBox(width: 8),
      SizedBox(width: 200, child: SakalTableHeaderBar.label('Remarks')),
      const SizedBox(width: 80), // reserves the Add/Remove icon columns' width
    ]);
  }

  Widget _buildLineCard(_JVLineRow row, int index, bool isMobile) {
    final accountField = SakalFieldCard(
      label: 'Account',
      required: true,
      editable: !_locked,
      showLabel: isMobile,
      child: FinanceAccountPicker(
        accounts: _pickableAccounts,
        initialValue: row.accountDisplay.isEmpty ? null : row.accountDisplay,
        enabled: !_locked,
        focusNode: row.accountFocusNode,
        decoration: SakalFieldCard.bareDecoration,
        onSelected: (a) => _onAccountSelected(row, a),
      ),
    );
    final parentGroupField = SakalFieldCard.readOnly(label: 'Parent Group', value: row.parentName.isEmpty ? '—' : row.parentName, showLabel: isMobile);
    final currencyField = SakalFieldCard.readOnly(label: 'Currency', value: row.accountCurrency.isEmpty ? '—' : row.accountCurrency, showLabel: isMobile);
    final amountField = SakalFieldCard(
      label: 'Amount',
      editable: !_locked,
      numeric: true,
      showLabel: isMobile,
      child: TextFormField(
        controller: row.amountCtrl,
        focusNode: row.amountFocusNode,
        enabled: !_locked,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,4}'))],
        decoration: SakalFieldCard.bareDecoration,
        textAlign: TextAlign.right,
        onChanged: (_) => setState(() {}),
      ),
    );
    final drCrField = SakalFieldCard(
      label: 'Dr / Cr',
      editable: !_locked,
      showLabel: isMobile,
      child: DropdownButtonFormField<String>(
        initialValue: row.natureDrCr,
        isExpanded: true,
        isDense: true,
        itemHeight: null,
        decoration: SakalFieldCard.bareDecoration,
        style: SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider)),
        items: const [DropdownMenuItem(value: 'DR', child: Text('DR')), DropdownMenuItem(value: 'CR', child: Text('CR'))],
        onChanged: _locked ? null : (v) => setState(() => row.natureDrCr = v ?? 'DR'),
      ),
    );
    final baseAmountField = SakalFieldCard.readOnly(label: 'Base Amount', value: AppNumberFormat.amount(row.amount * _baseRate, 'INTERNATIONAL'), numeric: true, showLabel: isMobile);
    final localAmountField = SakalFieldCard.readOnly(label: 'Local Amount', value: AppNumberFormat.amount(row.amount * _localRate, 'INTERNATIONAL'), numeric: true, showLabel: isMobile);
    final partyAmountField = SakalFieldCard.readOnly(label: 'Party Amount', value: AppNumberFormat.amount(row.amount * _partyRateFor(row), 'INTERNATIONAL'), numeric: true, showLabel: isMobile);
    final remarksField = SakalFieldCard(
      label: 'Remarks',
      editable: !_locked,
      showLabel: isMobile,
      child: TextFormField(
        controller: row.remarksCtrl,
        enabled: !_locked,
        decoration: SakalFieldCard.bareDecoration,
        textInputAction: index < _lines.length - 1 ? TextInputAction.next : TextInputAction.done,
        onFieldSubmitted: (_) {
          if (index < _lines.length - 1) {
            _lines[index + 1].accountFocusNode.requestFocus();
          } else {
            row.addButtonFocusNode.requestFocus();
          }
        },
      ),
    );
    final addButton = IconButton(focusNode: row.addButtonFocusNode, icon: const Icon(Icons.add_circle_outline, size: 20, color: AppColors.primary), tooltip: 'Add line', onPressed: _addLine);
    final removeButton = IconButton(icon: const Icon(Icons.close, size: 18, color: AppColors.negative), tooltip: 'Remove line', onPressed: () => _removeLine(row));

    final extraContent = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (row.autoCreatesBill)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            row.accountNature == 'Customer' ? 'This line creates a new receivable (Invoice) against this customer.' : 'This line creates a new payable (Bill) against this supplier.',
            style: const TextStyle(fontSize: 11, color: AppColors.secondary, fontStyle: FontStyle.italic),
          ),
        ),
      if (row.canOptIntoSettlement)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(children: [
            Checkbox(
              value: row.settleAgainstBill,
              onChanged: _locked
                  ? null
                  : (v) {
                      setState(() {
                        row.settleAgainstBill = v ?? false;
                        if (!row.settleAgainstBill) row.selectedBill = null;
                      });
                    },
            ),
            const Text('Settle against an existing bill', style: TextStyle(fontSize: 12)),
            if (row.settleAgainstBill) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: _locked ? null : () => _pickSettlementBill(row),
                child: Text(row.selectedBill != null ? 'Bill: ${row.selectedBill!['trans_no']}' : 'Pick a bill…'),
              ),
            ],
          ]),
        ),
    ]);

    if (isMobile) {
      return Card(
        elevation: 0,
        margin: const EdgeInsets.only(bottom: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SizedBox(width: 320, child: accountField),
              SizedBox(width: 150, child: parentGroupField),
              SizedBox(width: 90, child: currencyField),
              SizedBox(width: 130, child: amountField),
              SizedBox(width: 90, child: drCrField),
              SizedBox(width: 120, child: baseAmountField),
              SizedBox(width: 120, child: localAmountField),
              SizedBox(width: 120, child: partyAmountField),
              SizedBox(width: 200, child: remarksField),
              if (!_locked) addButton,
              if (!_locked && _lines.length > 1) removeButton,
            ]),
            extraContent,
          ]),
        ),
      );
    }

    // Desktop — a continuous row under _buildLinesHeader's dark bar, same
    // column widths so the two stay pixel-aligned (see CLAUDE.md's
    // "Line-items grid" mandatory pattern). Horizontal scroll (via the
    // SakalScrollableTable wrapping this in _buildLinesSection) replaces
    // the old Wrap, which pushed fields onto a second line once the row's
    // fixed column widths exceeded the viewport.
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 320, child: accountField),
          const SizedBox(width: 8),
          SizedBox(width: 150, child: parentGroupField),
          const SizedBox(width: 8),
          SizedBox(width: 90, child: currencyField),
          const SizedBox(width: 8),
          SizedBox(width: 130, child: amountField),
          const SizedBox(width: 8),
          SizedBox(width: 90, child: drCrField),
          const SizedBox(width: 8),
          SizedBox(width: 120, child: baseAmountField),
          const SizedBox(width: 8),
          SizedBox(width: 120, child: localAmountField),
          const SizedBox(width: 8),
          SizedBox(width: 120, child: partyAmountField),
          const SizedBox(width: 8),
          SizedBox(width: 200, child: remarksField),
          SizedBox(width: 40, child: !_locked ? addButton : null),
          SizedBox(width: 40, child: (!_locked && _lines.length > 1) ? removeButton : null),
        ]),
        extraContent,
      ]),
    );
  }
}
