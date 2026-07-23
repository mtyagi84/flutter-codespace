import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_presets.dart';
import '../../../../core/utils/app_number_format.dart';
import '../../../../core/utils/local_id.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/sakal_field_card.dart';
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
class _JVLineRow {
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
    with ScreenPermissionMixin<JournalVoucherEntryScreen> {
  @override
  String get screenName => RouteNames.journalEntry;

  FinanceVoucherRepository get _ds => ref.read(financeVoucherRepositoryProvider);

  String? _transNo;
  DateTime _transDate = DateTime.now();
  bool _isPosted = false;
  String? _locationId;

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

  // All postable accounts (Customer/Supplier included even if not
  // posting_allowed) — the SAME shared cache Payment/Receipt Voucher and
  // Purchase Order use. Cash/Bank is filtered out client-side, only for
  // this screen's own picker instance — the shared cache itself is
  // untouched (other screens still need Cash/Bank in it).
  List<Map<String, dynamic>> _allAccounts = [];
  List<Map<String, dynamic>> get _pickableAccounts =>
      _allAccounts.where((a) => a['account_nature'] != 'Cash' && a['account_nature'] != 'Bank').toList();

  final List<_JVLineRow> _lines = [];
  final List<_JVLineRow> _pendingLineDisposal = [];

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
    _addLine();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _baseRateCtrl.dispose();
    _localRateCtrl.dispose();
    _refNoCtrl.dispose();
    _remarksCtrl.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    for (final l in _pendingLineDisposal) {
      l.dispose();
    }
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
      _baseCcy = await ref.read(baseCurrencyProvider.future);
      _localCcy = await ref.read(localCurrencyProvider.future);
      _currencies = await ref.read(currenciesProvider.future);
      _allAccounts = await ref.read(accountsProvider.future);

      if (widget.editTransNo != null) {
        final header = await _ds.getHeader(clientId: session.clientId, companyId: session.companyId, transNo: widget.editTransNo!, transDate: widget.editTransDate);
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
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load: $e';
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

  void _addLine() {
    final row = _JVLineRow();
    setState(() => _lines.add(row));
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
    // same setState that removes it from the tree — deferred to this
    // screen's own dispose(), same fix already applied once on Cash
    // Receipt's own bill rows for the identical bug class.
    _pendingLineDisposal.add(row);
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
    } catch (e) {
      _showSnack('Could not load pending bills: $e', color: AppColors.negative);
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
    } on DioException catch (e) {
      setState(() {
        _saving = false;
        _actionError = _serverError(e);
      });
      return false;
    } catch (e) {
      setState(() {
        _saving = false;
        _actionError = 'Unexpected error: $e';
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
    } on DioException catch (e) {
      setState(() => _actionError = _serverError(e));
    } catch (e) {
      setState(() => _actionError = 'Unexpected error: $e');
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
    } on DioException catch (e) {
      setState(() => _actionError = _serverError(e));
    } catch (e) {
      setState(() => _actionError = 'Unexpected error: $e');
    } finally {
      if (mounted) setState(() => _reversing = false);
    }
  }

  String _serverError(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['message'] is String) return data['message'] as String;
    return e.message ?? e.toString();
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
    } catch (e) {
      if (mounted) _showSnack('Print failed: $e', color: AppColors.negative);
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: isMobile
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _buildTitleBlock(),
                  const SizedBox(height: 10),
                  Wrap(spacing: 8, runSpacing: 8, children: _buildActionButtons(canSave, showApprove, showReverse)),
                ])
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _buildTitleBlock()),
                  ..._buildActionButtons(canSave, showApprove, showReverse),
                ]),
        ),
        const Divider(height: 20),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AppColors.negative))),
                    if (_actionError != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_actionError!, style: const TextStyle(color: AppColors.negative))),
                    _buildHeaderSection(),
                    const SizedBox(height: 20),
                    _buildLinesSection(),
                  ]),
                ),
        ),
      ],
    );
  }

  Widget _buildTitleBlock() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(_transNo ?? 'New Journal Voucher', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
      const SizedBox(height: 4),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: (_isPosted ? AppColors.positive : AppColors.secondary).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
        child: Text(_isPosted ? 'Posted' : 'Draft', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _isPosted ? AppColors.positive : AppColors.secondary)),
      ),
    ]);
  }

  List<Widget> _buildActionButtons(bool canSave, bool showApprove, bool showReverse) {
    return [
      if (_transNo != null) Tooltip(message: _printing ? 'Preparing PDF…' : 'Print', child: IconButton(icon: _printing ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.print_outlined), color: AppColors.primary, onPressed: _printing ? null : _print)),
      if (!_locked && !_isNew) OutlinedButton.icon(onPressed: _applyCopy, icon: const Icon(Icons.copy_outlined, size: 16), label: const Text('Copy')),
      if (showReverse) OutlinedButton.icon(onPressed: _reversing ? null : _reverse, icon: _reversing ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.undo, size: 16), label: const Text('Reverse')),
      if (canSave) FilledButton.icon(onPressed: _saving ? null : () => _saveDraft(), icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save_outlined), label: const Text('Save Draft')),
      if (showApprove) FilledButton.icon(onPressed: _approving ? null : _approve, style: FilledButton.styleFrom(backgroundColor: AppColors.positive), icon: _approving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check_circle_outline), label: const Text('Approve')),
    ];
  }

  Widget _buildHeaderSection() {
    return Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.start, children: [
      SizedBox(width: 200, child: SakalFieldCard.readOnly(label: 'Voucher No', value: _transNo ?? '—')),
      SizedBox(
        width: 170,
        child: InkWell(onTap: !_locked ? _pickDate : null, child: SakalFieldCard.readOnly(label: 'Voucher Date', value: _displayDate(_transDate))),
      ),
      SizedBox(
        width: 220,
        child: SakalFieldCard(
          label: 'Currency',
          required: true,
          editable: !_locked,
          child: DropdownButtonFormField<String>(
            initialValue: _currencyId,
            isExpanded: true,
            isDense: true,
            itemHeight: null,
            decoration: SakalFieldCard.bareDecoration,
            style: SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider)),
            items: _currencies.map((c) => DropdownMenuItem(value: c['id'] as String, child: Text(c['currency_id'] as String))).toList(),
            onChanged: _locked
                ? null
                : (v) {
                    final match = _currencies.firstWhere((c) => c['id'] == v, orElse: () => const {});
                    if (match.isNotEmpty) _onCurrencySelected(match);
                  },
          ),
        ),
      ),
      if (_currencyCode.isNotEmpty && _currencyCode != _baseCcy)
        SizedBox(
          width: 200,
          child: SakalFieldCard(label: '1 $_currencyCode = ? $_baseCcy', editable: !_locked, numeric: true, child: SakalReciprocalRateField(controller: _baseRateCtrl, enabled: !_locked, onChanged: (_) => setState(() {}))),
        ),
      if (_currencyCode.isNotEmpty && _currencyCode != _localCcy && _localCcy != _baseCcy)
        SizedBox(
          width: 200,
          child: SakalFieldCard(label: '1 $_currencyCode = ? $_localCcy', editable: !_locked, numeric: true, child: SakalReciprocalRateField(controller: _localRateCtrl, enabled: !_locked, onChanged: (_) => setState(() {}))),
        ),
      SizedBox(
        width: 180,
        child: SakalFieldCard(
          label: 'Reference No',
          editable: !_locked,
          child: TextFormField(controller: _refNoCtrl, enabled: !_locked, decoration: SakalFieldCard.bareDecoration),
        ),
      ),
      SizedBox(
        width: 170,
        child: InkWell(
          onTap: !_locked
              ? () async {
                  final d = await showDatePicker(context: context, initialDate: _refDate ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime(2100));
                  if (d != null) setState(() => _refDate = d);
                }
              : null,
          child: SakalFieldCard.readOnly(label: 'Reference Date', value: _refDate != null ? _displayDate(_refDate) : '—'),
        ),
      ),
      SizedBox(
        width: 320,
        child: SakalFieldCard(label: 'Remarks', editable: !_locked, child: TextFormField(controller: _remarksCtrl, enabled: !_locked, decoration: SakalFieldCard.bareDecoration)),
      ),
    ]);
  }

  Widget _buildLinesSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Expanded(child: Text('Account Lines', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
        Text(
          'Dr ${AppNumberFormat.amount(_totalDr, 'INTERNATIONAL')}  /  Cr ${AppNumberFormat.amount(_totalCr, 'INTERNATIONAL')}',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _isBalanced ? AppColors.positive : AppColors.negative),
        ),
      ]),
      const SizedBox(height: 8),
      for (var i = 0; i < _lines.length; i++) _buildLineCard(_lines[i], i),
    ]);
  }

  Widget _buildLineCard(_JVLineRow row, int index) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: 320,
              child: SakalFieldCard(
                label: 'Account',
                required: true,
                editable: !_locked,
                child: FinanceAccountPicker(
                  accounts: _pickableAccounts,
                  initialValue: row.accountDisplay.isEmpty ? null : row.accountDisplay,
                  enabled: !_locked,
                  focusNode: row.accountFocusNode,
                  decoration: SakalFieldCard.bareDecoration,
                  onSelected: (a) => _onAccountSelected(row, a),
                ),
              ),
            ),
            SizedBox(width: 150, child: SakalFieldCard.readOnly(label: 'Parent Group', value: row.parentName.isEmpty ? '—' : row.parentName)),
            SizedBox(width: 90, child: SakalFieldCard.readOnly(label: 'Currency', value: row.accountCurrency.isEmpty ? '—' : row.accountCurrency)),
            SizedBox(
              width: 130,
              child: SakalFieldCard(
                label: 'Amount',
                editable: !_locked,
                numeric: true,
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
              ),
            ),
            SizedBox(
              width: 90,
              child: SakalFieldCard(
                label: 'Dr / Cr',
                editable: !_locked,
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
              ),
            ),
            SizedBox(width: 120, child: SakalFieldCard.readOnly(label: 'Base Amount', value: AppNumberFormat.amount(row.amount * _baseRate, 'INTERNATIONAL'), numeric: true)),
            SizedBox(width: 120, child: SakalFieldCard.readOnly(label: 'Local Amount', value: AppNumberFormat.amount(row.amount * _localRate, 'INTERNATIONAL'), numeric: true)),
            SizedBox(width: 120, child: SakalFieldCard.readOnly(label: 'Party Amount', value: AppNumberFormat.amount(row.amount * _partyRateFor(row), 'INTERNATIONAL'), numeric: true)),
            SizedBox(
              width: 200,
              child: SakalFieldCard(
                label: 'Remarks',
                editable: !_locked,
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
              ),
            ),
            if (!_locked)
              IconButton(focusNode: row.addButtonFocusNode, icon: const Icon(Icons.add_circle_outline, size: 20, color: AppColors.primary), tooltip: 'Add line', onPressed: _addLine),
            if (!_locked && _lines.length > 1) IconButton(icon: const Icon(Icons.close, size: 18, color: AppColors.negative), tooltip: 'Remove line', onPressed: () => _removeLine(row)),
          ]),
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
        ]),
      ),
    );
  }
}
