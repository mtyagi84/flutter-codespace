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
import '../../../../core/utils/deferred_row_disposal.dart';
import '../../../../core/utils/local_id.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/sakal_autocomplete.dart';
import '../../../../core/widgets/sakal_field_card.dart';
import '../../../../core/widgets/sakal_field_row.dart';
import '../../../../core/widgets/sakal_header_action_button.dart';
import '../../../../core/printing/print_engine.dart';
import '../../../../core/printing/print_template_provider.dart';
import '../../domain/repositories/cash_receipt_repository.dart';
import '../providers/cash_receipt_providers.dart';

/// One pending bill row shown to the cashier, with the three currency
/// columns the user explicitly asked for (Customer/Base/Local) plus the
/// single editable "Apply" field (entered in LOCAL currency, per the
/// confirmed design — the backend waterfalls it across the local/base
/// cash pools automatically at Approve time).
class _BillRow implements DisposableRow {
  final String invBillNo;
  final String invBillDate;
  final String partyCurrency;
  final double balancePartyCcy;
  double balanceBaseCcy = 0;
  double balanceLocalCcy = 0;
  final TextEditingController applyCtrl = TextEditingController();
  final FocusNode applyFocusNode = FocusNode();

  _BillRow({
    required this.invBillNo,
    required this.invBillDate,
    required this.partyCurrency,
    required this.balancePartyCcy,
  });

  double get applyLocal => double.tryParse(applyCtrl.text) ?? 0;

  @override
  void dispose() {
    applyCtrl.dispose();
    applyFocusNode.dispose();
  }
}

class CashReceiptEntryScreen extends ConsumerStatefulWidget {
  final String? editReceiptNo;
  const CashReceiptEntryScreen({super.key, this.editReceiptNo});

  @override
  ConsumerState<CashReceiptEntryScreen> createState() => _CashReceiptEntryScreenState();
}

class _CashReceiptEntryScreenState extends ConsumerState<CashReceiptEntryScreen>
    with ScreenPermissionMixin<CashReceiptEntryScreen>, ScreenHeaderMixin<CashReceiptEntryScreen>, DeferredRowDisposal<CashReceiptEntryScreen> {
  // Entry screen is not itself a menu item — Menu -> List -> Entry pattern.
  @override
  String get screenName => RouteNames.salesReceipts;

  @override
  ScreenHeaderInfo buildScreenHeader() {
    // Desktop-only (user-confirmed) — all action buttons consolidated into
    // the TopBar via SakalHeaderActionButton for consistent label+icon
    // styling app-wide. Mobile keeps the body-level button (see
    // _buildSaveButton/build()) since there's no spare AppBar width there —
    // same reasoning as the company-name fix.
    final locked = _status != 'DRAFT';
    final canSaveNow = !locked && canAdd;
    final showDesktopActions = !Responsive.isMobile(context);
    return ScreenHeaderInfo(
      title: _receiptNo ?? 'New Cash Receipt',
      badgeText: _status,
      badgeColor: _status == 'APPROVED' ? AppColors.positive : AppColors.secondary,
      actions: showDesktopActions
          ? [
              if (canSaveNow)
                SakalHeaderActionButton(
                  label: 'Save & Collect', icon: Icons.check_circle_outline, kind: SakalActionKind.save,
                  loading: _saving, onPressed: _saving ? null : () => _saveAndApprove(),
                ),
              if (_receiptNo != null && _status == 'APPROVED')
                SakalHeaderActionButton(
                  label: 'Print', icon: Icons.print_outlined, kind: SakalActionKind.neutral,
                  loading: _printing, onPressed: _printing ? null : _printReceipt,
                ),
            ]
          : ((_receiptNo != null && _status == 'APPROVED') ? [_buildPrintButton()] : const []),
    );
  }

  CashReceiptRepository get _ds => ref.read(cashReceiptRepositoryProvider);

  String? _receiptNo;
  DateTime _receiptDate = DateTime.now();
  String _status = 'DRAFT';

  // Prefilled, read-only — from ric_user_quick_invoice_setup (never
  // written to by this screen).
  String? _locationId;
  String? _locationName;
  String? _localCashAccountDisplay;
  String? _baseCashAccountDisplay;
  bool _quickSetupMissing = false;

  String? _customerId;
  String? _customerDisplay;
  final _remarksCtrl = TextEditingController();

  final _localAmountCtrl = TextEditingController();
  final _baseAmountCtrl = TextEditingController();

  String? _baseCcy;
  String? _localCcy;
  double _baseToLocalRate = 1;

  // Rows swapped out when the pending-bills list is reloaded (customer
  // change, date change, reopening a draft) are never disposed
  // synchronously inside the same setState that removes them — Flutter
  // may still reference an outgoing row's FocusNode this same frame.
  // Deferred all the way to this screen's own dispose() via DeferredRowDisposal.
  final List<_BillRow> _bills = [];
  final _billSearchCtrl = TextEditingController();
  String _billSearchText = '';

  bool _loading = true;
  String? _error;
  String? _actionError;
  bool _saving = false;
  bool _printing = false;
  bool _loadingBills = false;

  List<Map<String, dynamic>> _postedVouchers = [];
  final Map<String, List<Map<String, dynamic>>> _voucherLines = {};
  List<Map<String, dynamic>> _users = [];
  String? _createdByUserId;
  String? _approvedByUserId;
  String? _resolveUserName(String? userId) {
    if (userId == null) return null;
    final match = _users.firstWhere((u) => u['id'] == userId, orElse: () => const {});
    return match['full_name'] as String?;
  }

  double get _localAmount => double.tryParse(_localAmountCtrl.text) ?? 0;
  double get _baseAmount => double.tryParse(_baseAmountCtrl.text) ?? 0;
  double get _headerTotalLocal => _localAmount + _baseAmount * _baseToLocalRate;
  double get _appliedTotal => _bills.fold(0.0, (sum, b) => sum + b.applyLocal);
  bool get _totalsMatch => (_appliedTotal - _headerTotalLocal).abs() < 0.01;

  List<_BillRow> get _filteredBills {
    final q = _billSearchText.trim().toLowerCase();
    if (q.isEmpty) return _bills;
    return _bills.where((b) => b.invBillNo.toLowerCase().contains(q)).toList();
  }

  // Distributes the header's total collected amount across the pending
  // bills oldest-first (bills already arrive ordered trans_date.asc from
  // getPendingBills), filling each bill's outstanding balance before
  // moving to the next — the cashier no longer has to hand-split a
  // collected amount across several invoices themselves.
  void _autoApplyOldestFirst() {
    var remaining = _headerTotalLocal;
    setState(() {
      for (final b in _bills) {
        if (remaining <= 0.001) {
          b.applyCtrl.text = '';
          continue;
        }
        final take = remaining >= b.balanceLocalCcy ? b.balanceLocalCcy : remaining;
        b.applyCtrl.text = _fmtNum(take);
        remaining -= take;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _remarksCtrl.dispose();
    _localAmountCtrl.dispose();
    _baseAmountCtrl.dispose();
    _billSearchCtrl.dispose();
    for (final b in _bills) {
      b.dispose();
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
      final currencies = await _ds.getCompanyCurrencies(companyId: session.companyId);
      _baseCcy = currencies['base_currency'] as String?;
      _localCcy = currencies['local_currency'] as String?;
      _users = await _ds.getUsersForAutocomplete(clientId: session.clientId, companyId: session.companyId);

      final setup = await _ds.getQuickInvoiceSetup(clientId: session.clientId, companyId: session.companyId, userId: session.userId);
      if (setup == null) {
        _quickSetupMissing = true;
      } else {
        _locationId = setup['location_id'] as String?;
        _locationName = (setup['location'] as Map<String, dynamic>?)?['location_name'] as String?;
        final local = setup['local_cash_account'] as Map<String, dynamic>?;
        final base = setup['base_cash_account'] as Map<String, dynamic>?;
        _localCashAccountDisplay = local != null ? '[${local['account_code']}] ${local['account_name']}' : null;
        _baseCashAccountDisplay = base != null ? '[${base['account_code']}] ${base['account_name']}' : null;
      }

      if (widget.editReceiptNo != null) {
        final header = await _ds.getHeader(clientId: session.clientId, companyId: session.companyId, receiptNo: widget.editReceiptNo!);
        if (header != null) {
          _receiptNo = header['receipt_no'] as String;
          _receiptDate = DateTime.parse(header['receipt_date'] as String);
          _status = header['status'] as String;
          _customerId = header['customer_id'] as String?;
          final customer = header['customer'] as Map<String, dynamic>?;
          _customerDisplay = customer != null ? '[${customer['account_code']}] ${customer['account_name']}' : '';
          _localAmountCtrl.text = _fmtNum(header['local_amount']);
          _baseAmountCtrl.text = _fmtNum(header['base_amount']);
          _remarksCtrl.text = header['remarks'] as String? ?? '';
          _createdByUserId = header['created_by'] as String?;
          _approvedByUserId = header['approved_by'] as String?;

          // A draft's location/cash accounts are tied to whoever ORIGINALLY
          // created it (fn_approve_cash_receipt resolves cash accounts from
          // header.created_by, never the re-opener) — never silently
          // substitute the current viewer's own Quick Invoice Setup here,
          // or a re-save would drift location_id to the wrong location.
          _locationId = header['location_id'] as String? ?? _locationId;
          final location = header['location'] as Map<String, dynamic>?;
          if (location != null) _locationName = location['location_name'] as String?;
        }
      }

      // Resolved AFTER the header (if any) has set the real _receiptDate —
      // a reopened old draft must not compute this against today's date.
      await _reloadBaseToLocalRate();
      if (_customerId != null) await _loadPendingBillsAndRestore(session);

      if (mounted) setState(() => _loading = false);
      if (_status == 'APPROVED') unawaited(_loadPostedVouchers());
    } catch (e, st) {
      AppLogger.error('CashReceiptLoad', e, st);
      if (mounted) {
        setState(() {
          _loading = false;
          _error = ErrorPresenter.format(e, action: 'load this receipt');
        });
      }
    }
  }

  Future<void> _reloadBaseToLocalRate() async {
    if (_baseCcy == null || _localCcy == null || _locationId == null) return;
    final session = ref.read(sessionProvider)!;
    final rate = await _ds.getExchangeRate(
      companyId: session.companyId, locationId: _locationId!,
      fromCurrency: _baseCcy!, toCurrency: _localCcy!, rateDate: _fmtDate(_receiptDate),
    );
    if (mounted) setState(() => _baseToLocalRate = rate ?? 1);
  }

  Future<void> _loadPostedVouchers() async {
    final session = ref.read(sessionProvider)!;
    try {
      final vouchers = await _ds.getPostedVouchers(clientId: session.clientId, companyId: session.companyId, receiptNo: _receiptNo!);
      final lines = <String, List<Map<String, dynamic>>>{};
      for (final v in vouchers) {
        lines[v['trans_no'] as String] = await _ds.getPostedVoucherLines(
          clientId: session.clientId, companyId: session.companyId,
          voucherNo: v['trans_no'] as String, voucherDate: v['trans_date'] as String,
        );
      }
      if (mounted) {
        setState(() {
          _postedVouchers = vouchers;
          _voucherLines
            ..clear()
            ..addAll(lines);
        });
      }
    } catch (e, st) {
      AppLogger.warn('CashReceiptLoadPostedVouchers', e, st: st); // best-effort
    }
  }

  // ── Customer / pending bills ──────────────────────────────────────────

  Future<List<Map<String, dynamic>>> _searchCustomers(String query) async {
    final session = ref.read(sessionProvider)!;
    if (_locationId == null) return [];
    try {
      return await _ds.getCustomersWithPendingBills(
        clientId: session.clientId, companyId: session.companyId, locationId: _locationId!, search: query,
      );
    } catch (e, st) {
      AppLogger.warn('CashReceiptSearchCustomers', e, st: st);
      return [];
    }
  }

  Future<void> _onCustomerSelected(Map<String, dynamic> row) async {
    final session = ref.read(sessionProvider)!;
    final account = row['account'] as Map<String, dynamic>?;
    setState(() {
      _customerId = row['account_id'] as String?;
      _customerDisplay = account != null ? '[${account['account_code']}] ${account['account_name']}' : '';
      for (final b in _bills) { deferRowDisposal(b); }
      _bills.clear();
    });
    await _loadPendingBillsAndRestore(session);
  }

  Future<void> _loadPendingBillsAndRestore(UserSession session) async {
    if (_customerId == null || _locationId == null) return;
    setState(() => _loadingBills = true);
    try {
      final savedLines = _receiptNo != null
          ? await _ds.getLines(clientId: session.clientId, companyId: session.companyId, receiptNo: _receiptNo!, receiptDate: _fmtDate(_receiptDate))
          : <Map<String, dynamic>>[];

      final newBills = <_BillRow>[];

      // A saved, APPROVED receipt is a locked historical record — show
      // ONLY the invoices it actually settled, built directly from its own
      // saved lines, never the live "still outstanding" list.
      // v_pending_bills excludes any bill this receipt fully paid off
      // (balance <= 0), so reusing it here would silently drop settled
      // bills from view (or worse, show an unrelated bill's now-reduced
      // balance in its place) — real bug found live in the QA pass. Saved
      // lines only carry applied_amount_local (already local currency, not
      // the original party-currency balance), so there's no rate math to
      // redo here — the applied amount IS the figure to show in all three
      // columns for a settled historical row. A DRAFT still shows live
      // pending bills (with rate-converted balances) so the cashier can
      // keep applying against them.
      if (_status == 'APPROVED') {
        for (final l in savedLines) {
          final applied = (l['applied_amount_local'] as num? ?? 0).toDouble();
          final bill = _BillRow(
            invBillNo: l['inv_bill_no'] as String,
            invBillDate: l['inv_bill_date'] as String,
            partyCurrency: l['bill_currency'] as String? ?? _localCcy ?? '',
            balancePartyCcy: applied,
          )
            ..balanceBaseCcy = applied
            ..balanceLocalCcy = applied;
          bill.applyCtrl.text = _fmtNum(applied);
          newBills.add(bill);
        }
      } else {
        final rows = await _ds.getPendingBills(companyId: session.companyId, locationId: _locationId!, accountId: _customerId!);

        // Resolve Base/Local currency-equivalent columns — one rate lookup
        // per distinct party_currency present, not per row.
        final rateCache = <String, double>{};
        for (final r in rows) {
          final ccy = r['party_currency'] as String;
          final balance = (r['balance_amount'] as num? ?? 0).toDouble();
          final bill = _BillRow(
            invBillNo: r['inv_bill_no'] as String,
            invBillDate: r['inv_bill_date'] as String,
            partyCurrency: ccy,
            balancePartyCcy: balance,
          );
          if (!rateCache.containsKey('$ccy>base') && _baseCcy != null) {
            rateCache['$ccy>base'] = await _ds.getExchangeRate(
                  companyId: session.companyId, locationId: _locationId!,
                  fromCurrency: ccy, toCurrency: _baseCcy!, rateDate: _fmtDate(_receiptDate),
                ) ??
                1;
          }
          if (!rateCache.containsKey('$ccy>local') && _localCcy != null) {
            rateCache['$ccy>local'] = await _ds.getExchangeRate(
                  companyId: session.companyId, locationId: _locationId!,
                  fromCurrency: ccy, toCurrency: _localCcy!, rateDate: _fmtDate(_receiptDate),
                ) ??
                1;
          }
          bill.balanceBaseCcy = balance * (rateCache['$ccy>base'] ?? 1);
          bill.balanceLocalCcy = balance * (rateCache['$ccy>local'] ?? 1);

          // Reopening a saved DRAFT — restore whatever was already applied.
          final saved = savedLines.firstWhere(
            (l) => l['inv_bill_no'] == bill.invBillNo && l['inv_bill_date'] == bill.invBillDate,
            orElse: () => const {},
          );
          if (saved.isNotEmpty) {
            bill.applyCtrl.text = _fmtNum(saved['applied_amount_local']);
          }
          newBills.add(bill);
        }
      }
      if (mounted) {
        setState(() {
          for (final b in _bills) { deferRowDisposal(b); }
          _bills
            ..clear()
            ..addAll(newBills);
          _loadingBills = false;
        });
      }
    } catch (e, st) {
      AppLogger.error('CashReceiptLoadPendingBills', e, st);
      if (mounted) setState(() => _loadingBills = false);
    }
  }

  // ── Save (auto-approves when online, queues Save only when offline) ───

  Future<bool> _saveAndApprove() async {
    if (_quickSetupMissing) {
      _showSnack('This user has no Quick Invoice Setup (Location + Cash Accounts) — ask an admin to configure it before collecting cash.', color: AppColors.negative);
      return false;
    }
    if (_customerId == null) {
      _showSnack('Select a customer.', color: AppColors.negative);
      return false;
    }
    if (_localAmount <= 0 && _baseAmount <= 0) {
      _showSnack('Enter a cash amount received, in local and/or base currency.', color: AppColors.negative);
      return false;
    }
    final appliedBills = _bills.where((b) => b.applyLocal > 0).toList();
    if (appliedBills.isEmpty) {
      _showSnack('Apply the receipt against at least one pending invoice.', color: AppColors.negative);
      return false;
    }
    if (!_totalsMatch) {
      _showSnack(
        'Applied total (${AppNumberFormat.amount(_appliedTotal, _numberFormat)}) does not match the header total (${AppNumberFormat.amount(_headerTotalLocal, _numberFormat)}).',
        color: AppColors.negative,
      );
      return false;
    }

    setState(() {
      _saving = true;
      _actionError = null;
    });
    final session = ref.read(sessionProvider)!;
    try {
      final header = {
        'client_id': session.clientId,
        'company_id': session.companyId,
        'location_id': _locationId,
        'receipt_no': _receiptNo,
        'receipt_date': _fmtDate(_receiptDate),
        'customer_id': _customerId,
        'local_amount': _localAmount,
        'base_amount': _baseAmount,
        'remarks': _remarksCtrl.text.trim(),
      };
      final lines = appliedBills
          .map((b) => {
                'inv_bill_no': b.invBillNo,
                'inv_bill_date': b.invBillDate,
                'bill_currency': b.partyCurrency,
                'applied_amount_local': b.applyLocal,
              })
          .toList();

      if (session.offlineMode) {
        final localId = generateLocalId();
        await ref.read(syncEngineProvider).enqueue(
          documentType: 'CASH_RECEIPT',
          documentId: localId,
          endpoint: '/rpc/fn_save_cash_receipt',
          payload: {'p_header': header, 'p_lines': lines, 'p_user_id': session.userId},
        );
        await _ds.cacheReceiptLocally(effectiveReceiptNo: localId, header: header, lines: lines);
        if (mounted) {
          setState(() {
            _receiptNo = localId;
            _saving = false;
          });
          _showSnack('Saved offline as $localId — will sync when online, then wait for Pending Approvals to post.', color: AppColors.secondary);
        }
        return true;
      }

      final receiptNo = await _ds.save(header: header, lines: lines, userId: session.userId);
      await _ds.approve(clientId: session.clientId, companyId: session.companyId, receiptNo: receiptNo, receiptDate: _fmtDate(_receiptDate), approvedBy: session.userId);
      if (mounted) {
        setState(() {
          _receiptNo = receiptNo;
          _status = 'APPROVED';
          _saving = false;
        });
        _showSnack('Cash Receipt $receiptNo collected and posted.', color: AppColors.positive);
        unawaited(_loadPostedVouchers());
      }
      return true;
    } catch (e, st) {
      AppLogger.error('CashReceiptSave', e, st);
      setState(() {
        _saving = false;
        _actionError = ErrorPresenter.format(e, action: 'save this receipt');
      });
      return false;
    }
  }

  // ── Print ─────────────────────────────────────────────────────────────

  Map<String, dynamic> _buildPrintDocument(Map<String, dynamic> company) {
    return {
      'company': company,
      'header': {
        'receipt_no': _receiptNo ?? '',
        'receipt_date': _displayDate(_receiptDate),
        'status': _status,
        'customer_name': _customerDisplay ?? '',
        'location_name': _locationName ?? '',
        'local_amount': _localAmount,
        'base_amount': _baseAmount,
        'total_local_equivalent': _headerTotalLocal,
        'remarks': _remarksCtrl.text,
        'signatures': {
          'prepared_by': _resolveUserName(_createdByUserId) ?? '',
          'authorised_by': _resolveUserName(_approvedByUserId) ?? '',
        },
      },
      'lines': _bills.where((b) => b.applyLocal > 0).map((b) => {
            'inv_bill_no': b.invBillNo,
            'inv_bill_date': b.invBillDate,
            'bill_currency': b.partyCurrency,
            'applied_amount_local': b.applyLocal,
          }).toList(),
      'totals': {},
    };
  }

  Future<void> _printReceipt() async {
    if (_receiptNo == null) return;
    setState(() => _printing = true);
    try {
      final company = await ref.read(companyDetailsProvider.future) ?? <String, dynamic>{};
      final template = await ref.read(printTemplateProvider('CASH_RECEIPT').future);
      final document = _buildPrintDocument(company);
      await PrintEngine.printDocument(template: template, document: document, filename: '$_receiptNo.pdf');
    } catch (e, st) {
      AppLogger.error('CashReceiptPrint', e, st);
      if (mounted) _showSnack(ErrorPresenter.format(e, action: 'print this receipt'), color: AppColors.negative);
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  String get _numberFormat => ref.watch(sessionProvider)?.numberFormat ?? 'INTERNATIONAL';

  String _fmtDate(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _displayDate(DateTime? d) {
    if (d == null) return 'Select date';
    const m = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day.toString().padLeft(2, '0')} ${m[d.month]} ${d.year}';
  }

  String _fmtNum(dynamic v) {
    final n = (v as num?)?.toDouble() ?? 0;
    return n == 0 ? '' : n.toString();
  }

  void _showSnack(String msg, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  Future<void> _pickDate() async {
    // No future dates — hard client-side guard mirroring the server's own
    // unconditional FUTURE_DATE_NOT_ALLOWED check at Approve.
    final d = await showDatePicker(context: context, initialDate: _receiptDate, firstDate: DateTime(2020), lastDate: DateTime.now());
    if (d != null) {
      setState(() => _receiptDate = d);
      await _reloadBaseToLocalRate();
      if (_customerId != null) await _loadPendingBillsAndRestore(ref.read(sessionProvider)!);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────
  // No Scaffold/AppBar here — every entry screen in this app is embedded
  // in the App Shell's own TopBar/Scaffold; a screen-level Scaffold would
  // nest a second app bar under the shell's, which is not how Sales
  // Delivery/Return/Invoice (or any other entry screen) are built.

  @override
  Widget build(BuildContext context) {
    // Title/status badge/Save & Collect/Print now live in the shared TopBar
    // via ScreenHeaderMixin on desktop (SakalHeaderActionButton, see
    // buildScreenHeader) — see CLAUDE.md's "Screen header" pattern. Mobile
    // keeps this body-level button since there's no spare AppBar width there.
    refreshScreenHeader();
    final locked = _status != 'DRAFT';
    final canSave = !locked && canAdd;
    final isMobile = Responsive.isMobile(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isMobile && canSave)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: _buildSaveButton(),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AppColors.negative))),
                    if (_quickSetupMissing)
                      Container(
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(color: AppColors.negative.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
                        child: const Text(
                          'No Quick Invoice Setup found for your user. Ask an admin to configure your Location, Local Cash Account and Base Cash Account before you can collect cash.',
                          style: TextStyle(color: AppColors.negative),
                        ),
                      ),
                    _buildPrefillSection(),
                    const SizedBox(height: 16),
                    _buildCashHeaderSection(locked),
                    const SizedBox(height: 16),
                    _buildCustomerSection(locked),
                    const SizedBox(height: 16),
                    if (_customerId != null) _buildPendingBillsSection(locked),
                    if (_actionError != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_actionError!, style: const TextStyle(color: AppColors.negative))),
                    if (_status == 'APPROVED') ...[const SizedBox(height: 24), _buildPostedVoucherSection()],
                  ]),
                ),
        ),
      ],
    );
  }

  Widget _buildSaveButton() => FilledButton.icon(
        onPressed: _saving ? null : () => _saveAndApprove(),
        icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check_circle_outline),
        label: const Text('Save & Collect'),
      );

  Widget _buildPrintButton() => Tooltip(
        message: _printing ? 'Preparing PDF…' : 'Print / Save as PDF',
        child: IconButton(
          icon: _printing ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.print_outlined),
          color: AppColors.primary,
          onPressed: _printing ? null : _printReceipt,
        ),
      );

  Widget _buildPrefillSection() {
    final isMobile = Responsive.isMobile(context);
    final locationField = SakalFieldCard.readOnly(label: 'Location', value: _locationName ?? '—');
    final localCashField = SakalFieldCard.readOnly(label: 'Local Cash Account', value: _localCashAccountDisplay ?? '—');
    final baseCashField = SakalFieldCard.readOnly(label: 'Base Cash Account', value: _baseCashAccountDisplay ?? '—');
    final dateField = InkWell(
      onTap: (_status == 'DRAFT') ? _pickDate : null,
      child: SakalFieldCard.readOnly(label: 'Receipt Date', value: _displayDate(_receiptDate)),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SakalFieldRow(isMobile: isMobile, children: [locationField, dateField]),
      const SizedBox(height: 12),
      SakalFieldRow(isMobile: isMobile, children: [localCashField, baseCashField]),
    ]);
  }

  Widget _buildCashHeaderSection(bool locked) {
    final isMobile = Responsive.isMobile(context);
    final localAmountField = SakalFieldCard(
      label: 'Cash Received (Local${_localCcy != null ? ' — $_localCcy' : ''})',
      editable: !locked,
      numeric: true,
      child: TextFormField(
        controller: _localAmountCtrl,
        enabled: !locked,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,4}'))],
        decoration: SakalFieldCard.bareDecoration,
        textAlign: TextAlign.right,
        onChanged: (_) => setState(() {}),
      ),
    );
    final baseAmountField = SakalFieldCard(
      label: 'Cash Received (Base${_baseCcy != null ? ' — $_baseCcy' : ''})',
      editable: !locked,
      numeric: true,
      child: TextFormField(
        controller: _baseAmountCtrl,
        enabled: !locked,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,4}'))],
        decoration: SakalFieldCard.bareDecoration,
        textAlign: TextAlign.right,
        onChanged: (_) => setState(() {}),
      ),
    );
    final totalField = SakalFieldCard.readOnly(
      label: 'Total Receipt (Local Equivalent)',
      value: AppNumberFormat.amount(_headerTotalLocal, _numberFormat),
      numeric: true,
    );
    final remarksField = SakalFieldCard(
      label: 'Remarks',
      editable: !locked,
      child: TextFormField(controller: _remarksCtrl, enabled: !locked, decoration: SakalFieldCard.bareDecoration),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SakalFieldRow(isMobile: isMobile, children: [localAmountField, baseAmountField, totalField]),
      const SizedBox(height: 12),
      SakalFieldRow(isMobile: isMobile, children: [remarksField]),
    ]);
  }

  Widget _buildCustomerSection(bool locked) {
    return SizedBox(
      width: 360,
      child: SakalFieldCard(
        label: 'Customer',
        required: true,
        editable: !locked,
        child: SakalAutocomplete<Map<String, dynamic>>(
          initialValue: (_customerDisplay == null || _customerDisplay!.isEmpty) ? null : TextEditingValue(text: _customerDisplay!),
          enabled: !locked,
          decoration: SakalFieldCard.bareDecoration,
          displayStringForOption: (o) {
            final acc = o['account'] as Map<String, dynamic>?;
            return acc != null ? '[${acc['account_code']}] ${acc['account_name']}' : '';
          },
          optionsBuilder: (textEditingValue) => _searchCustomers(textEditingValue.text),
          onSelected: _onCustomerSelected,
        ),
      ),
    );
  }

  Widget _buildPendingBillsSection(bool locked) {
    if (_loadingBills) {
      return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (_bills.isEmpty) {
      return const Padding(padding: EdgeInsets.all(16), child: Text('This customer has no pending invoices at this location.'));
    }

    final filtered = _filteredBills;
    final isMobile = Responsive.isMobile(context);
    final searchField = TextField(
      controller: _billSearchCtrl,
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Search bill no…',
        prefixIcon: const Icon(Icons.search, size: 18),
        suffixIcon: _billSearchText.isNotEmpty
            ? IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: () => setState(() { _billSearchCtrl.clear(); _billSearchText = ''; }))
            : null,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onChanged: (v) => setState(() => _billSearchText = v),
    );
    final autoApplyButton = OutlinedButton.icon(
      onPressed: _headerTotalLocal > 0 ? _autoApplyOldestFirst : null,
      icon: const Icon(Icons.auto_fix_high, size: 16),
      label: const Text('Auto-Apply (Oldest First)'),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Expanded(child: Text('Pending Invoices', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
        Text(
          'Applied: ${AppNumberFormat.amount(_appliedTotal, _numberFormat)} / ${AppNumberFormat.amount(_headerTotalLocal, _numberFormat)}',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _totalsMatch ? AppColors.positive : AppColors.negative),
        ),
      ]),
      const SizedBox(height: 8),
      if (!locked)
        isMobile
            ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                searchField,
                const SizedBox(height: 8),
                autoApplyButton,
              ])
            : Row(children: [
                Expanded(child: searchField),
                const SizedBox(width: 8),
                autoApplyButton,
              ]),
      const SizedBox(height: 8),
      if (filtered.isEmpty)
        const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('No bills match your search.'))
      else
        for (var i = 0; i < filtered.length; i++) _buildBillCard(filtered[i], i, filtered, locked),
    ]);
  }

  Widget _buildBillCard(_BillRow bill, int index, List<_BillRow> siblings, bool locked) {
    final isMobile = Responsive.isMobile(context);
    final isFullyApplied = bill.balanceLocalCcy > 0 && (bill.applyLocal - bill.balanceLocalCcy).abs() < 0.01;
    final billLabel = Text('${bill.invBillNo}\n${bill.invBillDate}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600));
    final balancePartyField = SakalFieldCard.readOnly(
      label: 'Balance (${bill.partyCurrency})',
      value: AppNumberFormat.amount(bill.balancePartyCcy, _numberFormat),
      numeric: true,
      height: 56,
    );
    final balanceBaseField = SakalFieldCard.readOnly(
      label: 'Balance (${_baseCcy ?? 'Base'})',
      value: AppNumberFormat.amount(bill.balanceBaseCcy, _numberFormat),
      numeric: true,
      height: 56,
    );
    final balanceLocalField = SakalFieldCard.readOnly(
      label: 'Balance (${_localCcy ?? 'Local'})',
      value: AppNumberFormat.amount(bill.balanceLocalCcy, _numberFormat),
      numeric: true,
      height: 56,
    );
    final applyField = SakalFieldCard(
      label: 'Apply (${_localCcy ?? 'Local'})',
      editable: !locked,
      numeric: true,
      height: 56,
      child: TextFormField(
        controller: bill.applyCtrl,
        focusNode: bill.applyFocusNode,
        enabled: !locked,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,4}'))],
        decoration: SakalFieldCard.bareDecoration,
        textAlign: TextAlign.right,
        textInputAction: index < siblings.length - 1 ? TextInputAction.next : TextInputAction.done,
        onChanged: (_) => setState(() {}),
        onFieldSubmitted: (_) {
          if (index < siblings.length - 1) {
            siblings[index + 1].applyFocusNode.requestFocus();
          } else {
            FocusScope.of(context).unfocus();
          }
        },
      ),
    );
    // Applies the full outstanding balance for this one bill with a single
    // tap instead of the cashier having to type/copy the exact number.
    final fullAmountToggle = locked
        ? const SizedBox(width: 24, height: 24)
        : Tooltip(
            message: isFullyApplied ? 'Full balance applied' : 'Apply full balance',
            child: Checkbox(
              value: isFullyApplied,
              onChanged: (v) => setState(() {
                bill.applyCtrl.text = (v ?? false) ? _fmtNum(bill.balanceLocalCcy) : '';
              }),
            ),
          );

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        // A Wrap of fixed-width fields leaves an empty gap on mobile (see
        // sakal_field_row.dart's own doc comment) — the bill label isn't a
        // SakalFieldCard so it doesn't fit SakalFieldRow's shape; stacked
        // manually instead, matching the same isMobile-conditional
        // Row/Column recipe used on every other filter/header Wrap in this
        // batch. Desktop keeps the original fixed-width Row layout.
        child: isMobile
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                billLabel,
                const SizedBox(height: 8),
                Row(children: [Expanded(child: balancePartyField), const SizedBox(width: 8), Expanded(child: balanceBaseField)]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: balanceLocalField),
                  const SizedBox(width: 8),
                  Expanded(child: applyField),
                  fullAmountToggle,
                ]),
              ])
            : Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                Expanded(child: billLabel),
                const SizedBox(width: 12),
                Expanded(child: balancePartyField),
                const SizedBox(width: 12),
                Expanded(child: balanceBaseField),
                const SizedBox(width: 12),
                Expanded(child: balanceLocalField),
                const SizedBox(width: 12),
                Expanded(child: applyField),
                fullAmountToggle,
              ]),
      ),
    );
  }

  // ── Posted journal entries (read-only, APPROVED receipts only) ────────
  Widget _buildPostedVoucherSection() {
    if (_voucherLines.isEmpty) return const SizedBox.shrink();

    Widget cell(String text, {TextAlign align = TextAlign.left, bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Text(text, textAlign: align, style: TextStyle(fontSize: 13, fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
        );

    Widget voucherCard(String voucherNo, List<Map<String, dynamic>> lines) {
      double totalDebit = 0, totalCredit = 0;
      for (final l in lines) {
        final amount = (l['trans_amount'] as num? ?? 0).toDouble();
        if (l['trans_nature'] == 'DR') {
          totalDebit += amount;
        } else {
          totalCredit += amount;
        }
      }
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Card(
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: Row(children: [
                const Expanded(child: Text('Voucher', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: AppColors.positive.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
                  child: Text(voucherNo, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.positive)),
                ),
              ]),
            ),
            for (var i = 0; i < lines.length; i++)
              Builder(builder: (_) {
                final l = lines[i];
                final account = l['account'] as Map<String, dynamic>?;
                final ledgerName = account != null ? '[${account['account_code']}] ${account['account_name']}' : '—';
                final amount = (l['trans_amount'] as num? ?? 0).toDouble();
                final isDr = l['trans_nature'] == 'DR';
                return Container(
                  color: i.isEven ? Colors.white : AppColors.background,
                  child: Row(children: [
                    Expanded(flex: 6, child: cell(ledgerName)),
                    Expanded(flex: 2, child: cell(isDr ? AppNumberFormat.amount(amount, _numberFormat) : '—', align: TextAlign.right)),
                    Expanded(flex: 2, child: cell(!isDr ? AppNumberFormat.amount(amount, _numberFormat) : '—', align: TextAlign.right)),
                  ]),
                );
              }),
            Container(
              decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.06), border: const Border(top: BorderSide(color: AppColors.border))),
              child: Row(children: [
                const Expanded(flex: 6, child: Padding(padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10), child: Text('Total', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)))),
                Expanded(flex: 2, child: cell(AppNumberFormat.amount(totalDebit, _numberFormat), align: TextAlign.right, bold: true)),
                Expanded(flex: 2, child: cell(AppNumberFormat.amount(totalCredit, _numberFormat), align: TextAlign.right, bold: true)),
              ]),
            ),
          ]),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Posted Journal Entries', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      for (final entry in _voucherLines.entries) voucherCard(entry.key, entry.value),
      if (_postedVouchers.isNotEmpty)
        Wrap(
          spacing: 6,
          children: _postedVouchers
              .map((v) => Chip(label: Text('${v['voucher_type_code']}: ${v['trans_no']}', style: const TextStyle(fontSize: 11))))
              .toList(),
        ),
    ]);
  }
}
