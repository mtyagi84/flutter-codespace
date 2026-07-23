import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/app_number_format.dart';
import '../../../../core/utils/local_id.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/sakal_field_card.dart';
import '../../../../core/widgets/sakal_reciprocal_rate_field.dart';
import '../../../../core/printing/print_engine.dart';
import '../../../../core/printing/print_template_provider.dart';
import '../../domain/repositories/expense_voucher_repository.dart';
import '../providers/expense_voucher_providers.dart';
import '../providers/finance_voucher_providers.dart';
import '../widgets/finance_account_picker.dart';

/// One expense line — Account + Amount (always an implicit debit, no
/// manual Dr/Cr per the user's final direction) + an optional Tax
/// Group. See docs/screens/expense_voucher.md for the full design
/// discussion (Odoo's automatic-tax model, this schema's own dormant
/// rim_tax_types.is_withholding brought to life here for the first time).
class _ExpenseLineRow {
  String? accountId;
  String accountDisplay = '';
  String? taxGroupId;
  String taxGroupDisplay = '';

  final TextEditingController amountCtrl = TextEditingController();
  final TextEditingController remarksCtrl = TextEditingController();
  final FocusNode accountFocusNode = FocusNode();
  final FocusNode amountFocusNode = FocusNode();
  final FocusNode addButtonFocusNode = FocusNode();

  double get amount => double.tryParse(amountCtrl.text) ?? 0;

  void dispose() {
    amountCtrl.dispose();
    remarksCtrl.dispose();
    accountFocusNode.dispose();
    amountFocusNode.dispose();
    addButtonFocusNode.dispose();
  }
}

class ExpenseVoucherEntryScreen extends ConsumerStatefulWidget {
  // No editTransDate — getHeader resolves by trans_no alone (picking the
  // latest trans_date), same convention as Cash Receipt's own getHeader.
  final String? editTransNo;
  const ExpenseVoucherEntryScreen({super.key, this.editTransNo});

  @override
  ConsumerState<ExpenseVoucherEntryScreen> createState() => _ExpenseVoucherEntryScreenState();
}

class _ExpenseVoucherEntryScreenState extends ConsumerState<ExpenseVoucherEntryScreen>
    with ScreenPermissionMixin<ExpenseVoucherEntryScreen> {
  @override
  String get screenName => RouteNames.expenseVoucherList;

  ExpenseVoucherRepository get _ds => ref.read(expenseVoucherRepositoryProvider);

  String? _transNo;
  DateTime _transDate = DateTime.now();
  String _status = 'DRAFT';
  String? _locationId;
  String? _postedVoucherNo;
  String? _postedVoucherDate;

  String _baseCcy = '';
  String _localCcy = '';
  List<Map<String, dynamic>> _allAccounts = [];
  List<Map<String, dynamic>> _currencies = [];
  List<Map<String, dynamic>> _taxGroups = [];

  List<Map<String, dynamic>> get _supplierAccounts =>
      _allAccounts.where((a) => a['account_nature'] == 'Supplier').toList();
  // Excludes Cash/Bank/Customer/Supplier — stricter than Journal
  // Voucher's own exclusion, per the user's own spec: Supplier is
  // already the fixed computed line, so a second Customer/Supplier
  // pick here would just be a confusing back door into what JV is for.
  List<Map<String, dynamic>> get _expenseAccounts => _allAccounts
      .where((a) => const {'Cash', 'Bank', 'Customer', 'Supplier'}.contains(a['account_nature']) == false)
      .toList();

  String? _supplierId;
  String _supplierDisplay = '';

  String? _currencyId;
  String _currencyCode = '';
  final _baseRateCtrl = TextEditingController(text: '1');
  final _localRateCtrl = TextEditingController(text: '1');

  final _billNoCtrl = TextEditingController();
  DateTime? _billDate;
  final _remarksCtrl = TextEditingController();

  final _supplierFocusNode = FocusNode();

  final List<_ExpenseLineRow> _lines = [];
  final List<_ExpenseLineRow> _pendingLineDisposal = [];

  // Client-side tax PREVIEW only (tax_group_id -> summed rate%, split by
  // is_withholding) — the backend (fn_approve_expense_voucher) is always
  // the authoritative computation. Mirrors Purchase Order's own
  // _taxGroupRatePct pattern, extended with the ADD/DEDUCT split.
  Map<String, double> _taxGroupAddPct = {};
  Map<String, double> _taxGroupDeductPct = {};

  bool _loading = true;
  String? _error;
  String? _actionError;
  bool _saving = false;
  bool _approving = false;
  bool _reversing = false;
  bool _printing = false;

  String _preparedByName = '';
  String _approvedByName = '';

  bool get _isNew => _transNo == null;
  bool get _locked => _status == 'APPROVED';

  double get _baseRate => double.tryParse(_baseRateCtrl.text) ?? 1;
  double get _localRate => double.tryParse(_localRateCtrl.text) ?? 1;

  double _lineAddAmount(_ExpenseLineRow row) {
    if (row.taxGroupId == null) return 0;
    return row.amount * (_taxGroupAddPct[row.taxGroupId] ?? 0) / 100;
  }

  double _lineDeductAmount(_ExpenseLineRow row) {
    if (row.taxGroupId == null) return 0;
    return row.amount * (_taxGroupDeductPct[row.taxGroupId] ?? 0) / 100;
  }

  double get _totalExpense => _lines.fold(0.0, (s, l) => s + l.amount);
  double get _totalAdd => _lines.fold(0.0, (s, l) => s + _lineAddAmount(l));
  double get _totalDeduct => _lines.fold(0.0, (s, l) => s + _lineDeductAmount(l));
  double get _netPayable => _totalExpense + _totalAdd - _totalDeduct;

  @override
  void initState() {
    super.initState();
    _addLine();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _init();
      _supplierFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _baseRateCtrl.dispose();
    _localRateCtrl.dispose();
    _billNoCtrl.dispose();
    _remarksCtrl.dispose();
    _supplierFocusNode.dispose();
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
      _allAccounts = await ref.read(accountsProvider.future);
      _currencies = await ref.read(currenciesProvider.future);
      _taxGroups = await ref.read(taxGroupsProvider.future);

      if (widget.editTransNo != null) {
        final header = await _ds.getHeader(clientId: session.clientId, companyId: session.companyId, transNo: widget.editTransNo!);
        if (header != null) {
          _transNo = header['trans_no'] as String?;
          _transDate = DateTime.parse(header['trans_date'] as String);
          _status = header['status'] as String? ?? 'DRAFT';
          _locationId = header['location_id'] as String? ?? _locationId;
          _postedVoucherNo = header['posted_voucher_no'] as String?;
          _postedVoucherDate = header['posted_voucher_date'] as String?;

          _supplierId = header['supplier_id'] as String?;
          final supplier = header['supplier'] as Map<String, dynamic>?;
          _supplierDisplay = supplier != null ? '[${supplier['account_code']}] ${supplier['account_name']}' : '';

          _currencyId = header['currency_id'] as String?;
          final currency = header['currency'] as Map<String, dynamic>?;
          _currencyCode = currency?['currency_id'] as String? ?? '';
          _baseRateCtrl.text = _fmtRate((header['rate_to_base'] as num? ?? 1).toDouble());
          _localRateCtrl.text = _fmtRate((header['rate_to_local'] as num? ?? 1).toDouble());

          _billNoCtrl.text = header['bill_no'] as String? ?? '';
          final billDateStr = header['bill_date'] as String?;
          _billDate = billDateStr != null ? DateTime.tryParse(billDateStr) : null;
          _remarksCtrl.text = header['remarks'] as String? ?? '';

          final createdByUser = header['created_by_user'] as Map<String, dynamic>?;
          final approvedByUser = header['approved_by_user'] as Map<String, dynamic>?;
          _preparedByName = createdByUser?['full_name'] as String? ?? '';
          _approvedByName = approvedByUser?['full_name'] as String? ?? '';

          final lines = await _ds.getLines(clientId: session.clientId, companyId: session.companyId, transNo: _transNo!, transDate: _fmtDate(_transDate));
          for (final l in _lines) {
            l.dispose();
          }
          _lines.clear();
          for (final l in lines) {
            final row = _ExpenseLineRow();
            final account = l['account'] as Map<String, dynamic>?;
            row.accountId = l['account_id'] as String?;
            row.accountDisplay = account != null ? '[${account['account_code']}] ${account['account_name']}' : '';
            row.amountCtrl.text = _fmtNum((l['amount'] as num? ?? 0).toDouble());
            row.taxGroupId = l['tax_group_id'] as String?;
            final taxGroup = l['tax_group'] as Map<String, dynamic>?;
            row.taxGroupDisplay = taxGroup != null ? '${taxGroup['group_code']} — ${taxGroup['group_name']}' : '';
            row.remarksCtrl.text = l['line_remarks'] as String? ?? '';
            _lines.add(row);
          }
          if (_lines.isEmpty) _addLine();
          await _refreshTaxPreview();
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

  // ── Supplier / currency handling ────────────────────────────────────

  Future<void> _onSupplierSelected(Map<String, dynamic> account) async {
    setState(() {
      _supplierId = account['id'] as String?;
      _supplierDisplay = FinanceAccountPicker.displayString(account);
    });
    // Auto-fetch the supplier's own default currency + rate — user can
    // still change both afterward.
    final supplierCcy = (account['rim_currencies'] as Map<String, dynamic>?)?['currency_id'] as String?;
    if (supplierCcy != null) {
      final match = _currencies.where((c) => c['currency_id'] == supplierCcy).toList();
      if (match.isNotEmpty) {
        await _onCurrencySelected(match.first);
        return;
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _onCurrencySelected(Map<String, dynamic> currency) async {
    setState(() {
      _currencyId = currency['id'] as String?;
      _currencyCode = currency['currency_id'] as String? ?? '';
    });
    if (_currencyCode.isEmpty || _locationId == null) return;
    final session = ref.read(sessionProvider)!;
    if (_currencyCode == _baseCcy) {
      _baseRateCtrl.text = '1';
    } else {
      final r = await _ds.getExchangeRate(companyId: session.companyId, locationId: _locationId!, fromCurrency: _currencyCode, toCurrency: _baseCcy, rateDate: _fmtDate(_transDate));
      _baseRateCtrl.text = _fmtRate(r ?? 1);
    }
    if (_currencyCode == _localCcy) {
      _localRateCtrl.text = '1';
    } else {
      final r = await _ds.getExchangeRate(companyId: session.companyId, locationId: _locationId!, fromCurrency: _currencyCode, toCurrency: _localCcy, rateDate: _fmtDate(_transDate));
      _localRateCtrl.text = _fmtRate(r ?? 1);
    }
    if (mounted) setState(() {});
  }

  // ── Lines ────────────────────────────────────────────────────────────

  void _addLine() {
    final row = _ExpenseLineRow();
    setState(() => _lines.add(row));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) row.accountFocusNode.requestFocus();
    });
  }

  void _removeLine(_ExpenseLineRow row) {
    setState(() {
      _lines.remove(row);
      if (_lines.isEmpty) _addLine();
    });
    // Deferred disposal — never dispose a just-removed row's controllers/
    // FocusNodes inside the same setState that removes it from the tree
    // (real bug class already fixed once on Cash Receipt/Journal Voucher).
    _pendingLineDisposal.add(row);
  }

  Future<void> _onLineAccountSelected(_ExpenseLineRow row, Map<String, dynamic> account) async {
    setState(() {
      row.accountId = account['id'] as String?;
      row.accountDisplay = FinanceAccountPicker.displayString(account);
      // Auto-suggest the account's own usual Tax Group — user-specified
      // "build it now" feature, saves a pick on lines that always use
      // the same tax.
      final defaultTaxGroupId = account['default_tax_group_id'] as String?;
      if (defaultTaxGroupId != null) {
        final match = _taxGroups.where((g) => g['id'] == defaultTaxGroupId).toList();
        if (match.isNotEmpty) {
          row.taxGroupId = defaultTaxGroupId;
          row.taxGroupDisplay = '${match.first['group_code']} — ${match.first['group_name']}';
        }
      }
    });
    await _refreshTaxPreview();
    if (mounted) setState(() {});
    row.amountFocusNode.requestFocus();
  }

  Future<void> _onLineTaxGroupSelected(_ExpenseLineRow row, Map<String, dynamic> group) async {
    setState(() {
      row.taxGroupId = group['id'] as String?;
      row.taxGroupDisplay = '${group['group_code']} — ${group['group_name']}';
    });
    await _refreshTaxPreview();
    if (mounted) setState(() {});
  }

  void _clearLineTaxGroup(_ExpenseLineRow row) {
    setState(() {
      row.taxGroupId = null;
      row.taxGroupDisplay = '';
    });
  }

  Future<void> _refreshTaxPreview() async {
    final groupIds = _lines.map((l) => l.taxGroupId).whereType<String>().toSet().toList();
    if (groupIds.isEmpty) {
      _taxGroupAddPct = {};
      _taxGroupDeductPct = {};
      return;
    }
    final memberMap = await _ds.getTaxGroupMemberTaxIds(groupIds);
    final allTaxIds = memberMap.values.expand((v) => v).toSet().toList();
    final rates = await _ds.getTaxRatesByIds(taxIds: allTaxIds, asOfDate: _fmtDate(_transDate));
    final withholding = await _ds.getTaxWithholdingFlags(allTaxIds);

    final addPct = <String, double>{};
    final deductPct = <String, double>{};
    for (final entry in memberMap.entries) {
      var add = 0.0, deduct = 0.0;
      for (final taxId in entry.value) {
        final rate = rates[taxId] ?? 0;
        if (withholding[taxId] == true) {
          deduct += rate;
        } else {
          add += rate;
        }
      }
      addPct[entry.key] = add;
      deductPct[entry.key] = deduct;
    }
    _taxGroupAddPct = addPct;
    _taxGroupDeductPct = deductPct;
  }

  // ── Save / Approve / Copy / Reverse ─────────────────────────────────

  Future<bool> _saveDraft() async {
    if (_supplierId == null) {
      _showSnack('Select a supplier.', color: AppColors.negative);
      return false;
    }
    if (_currencyId == null) {
      _showSnack('Select a currency.', color: AppColors.negative);
      return false;
    }
    if (_billNoCtrl.text.trim().isEmpty || _billDate == null) {
      _showSnack('Enter the supplier\'s Bill No and Bill Date.', color: AppColors.negative);
      return false;
    }
    final validLines = _lines.where((l) => l.accountId != null && l.amount > 0).toList();
    if (validLines.isEmpty) {
      _showSnack('Add at least one expense line.', color: AppColors.negative);
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
        'trans_no': _transNo ?? '',
        'trans_date': _fmtDate(_transDate),
        'supplier_id': _supplierId,
        'currency_id': _currencyId,
        'rate_to_base': _baseRate,
        'rate_to_local': _localRate,
        'bill_no': _billNoCtrl.text.trim(),
        'bill_date': _fmtDate(_billDate!),
        'remarks': _remarksCtrl.text.trim(),
      };
      final lines = validLines.map((l) => {
            'account_id': l.accountId,
            'amount': l.amount,
            'tax_group_id': l.taxGroupId,
            'line_remarks': l.remarksCtrl.text.trim(),
          }).toList();

      if (session.offlineMode) {
        final localId = generateLocalId();
        await ref.read(syncEngineProvider).enqueue(
          documentType: 'EXPENSE_VOUCHER',
          documentId: localId,
          endpoint: '/rpc/fn_save_expense_voucher',
          payload: {'p_header': header, 'p_lines': lines, 'p_user_id': session.userId},
        );
        await _ds.cacheVoucherLocally(effectiveTransNo: localId, header: header, lines: lines);
        if (mounted) {
          setState(() {
            _transNo = localId;
            _saving = false;
          });
          _showSnack('Saved offline as $localId — will sync when online.', color: AppColors.secondary);
        }
        return true;
      }

      final savedTransNo = await _ds.save(header: header, lines: lines, userId: session.userId);
      await _ds.cacheVoucherLocally(effectiveTransNo: savedTransNo, header: header, lines: lines);

      if (mounted) {
        setState(() {
          _transNo = savedTransNo;
          _saving = false;
        });
        _showSnack('Expense Voucher $savedTransNo saved.', color: AppColors.positive);
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
        title: const Text('Approve Expense Voucher'),
        content: Text('This creates a bill of ${AppNumberFormat.amount(_netPayable, 'INTERNATIONAL')} $_currencyCode against the supplier and posts to the General Ledger. Continue?'),
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
      await _ds.approve(clientId: session.clientId, companyId: session.companyId, locationId: _locationId!, transNo: _transNo!, transDate: _fmtDate(_transDate), approvedBy: session.userId);
      if (mounted) {
        _showSnack('Expense Voucher $_transNo approved.', color: AppColors.positive);
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
      _status = 'DRAFT';
      _transDate = DateTime.now();
      _postedVoucherNo = null;
      _postedVoucherDate = null;
      _billNoCtrl.clear();
      _billDate = null;
    });
    _showSnack('Copied as a new unsaved draft — Save to assign a new voucher number.', color: AppColors.secondary);
  }

  Future<void> _reverse() async {
    if (_postedVoucherNo == null || _postedVoucherDate == null) return;
    final session = ref.read(sessionProvider)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reverse Expense Voucher'),
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
      // fn_reverse_voucher operates on the POSTED GL voucher (posted_voucher_no,
      // coded EXP), not this document's own trans_no (coded EXV) — those are
      // deliberately two different numbering sequences (see migration 107).
      final res = await ref.read(financeVoucherRepositoryProvider).reverseVoucher(
            clientId: session.clientId,
            companyId: session.companyId,
            transNo: _postedVoucherNo!,
            transDate: _postedVoucherDate!,
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
        'voucher_no': _transNo ?? '',
        'trans_date': _displayDate(_transDate),
        'supplier_name': _supplierDisplay,
        'currency_code': _currencyCode,
        'bill_no': _billNoCtrl.text,
        'bill_date': _billDate != null ? _displayDate(_billDate) : '',
        'remarks': _remarksCtrl.text,
        'signatures': {
          'prepared_by': _preparedByName,
          'authorised_by': _approvedByName,
        },
      },
      'lines': _lines.where((l) => l.amount > 0).map((l) => {
            'account_name': l.accountDisplay,
            'amount': l.amount,
            'tax_group_name': l.taxGroupDisplay,
            'remarks': l.remarksCtrl.text,
          }).toList(),
      'totals': {
        'total_expense_display': AppNumberFormat.amount(_totalExpense, 'INTERNATIONAL'),
        'net_payable_display': AppNumberFormat.amount(_netPayable, 'INTERNATIONAL'),
      },
    };
  }

  Future<void> _print() async {
    if (_transNo == null) return;
    setState(() => _printing = true);
    try {
      final company = await ref.read(companyDetailsProvider.future) ?? <String, dynamic>{};
      final template = await ref.read(printTemplateProvider('EXPENSE_VOUCHER').future);
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

  String _fmtNum(double n) => n == 0 ? '' : _trimZeros(n);
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
      if (_currencyId != null) {
        final match = _currencies.where((c) => c['id'] == _currencyId).toList();
        if (match.isNotEmpty) await _onCurrencySelected(match.first);
      }
      await _refreshTaxPreview();
      if (mounted) setState(() {});
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isMobile = Responsive.isMobile(context);
    final canSave = !_locked && (_isNew ? canAdd : canEdit);
    final showApprove = !_locked && canApprove && !_isNew;
    final showReverse = _locked && canApprove && _postedVoucherNo != null;

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
      Text(_transNo ?? 'New Expense Voucher', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
      const SizedBox(height: 4),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: (_locked ? AppColors.positive : AppColors.secondary).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
        child: Text(_locked ? 'Posted' : 'Draft', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _locked ? AppColors.positive : AppColors.secondary)),
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
        width: 300,
        child: SakalFieldCard(
          label: 'Supplier',
          required: true,
          editable: !_locked,
          child: FinanceAccountPicker(
            key: ValueKey(_supplierDisplay),
            accounts: _supplierAccounts,
            initialValue: _supplierDisplay.isEmpty ? null : _supplierDisplay,
            enabled: !_locked,
            focusNode: _supplierFocusNode,
            decoration: SakalFieldCard.bareDecoration,
            onSelected: _onSupplierSelected,
          ),
        ),
      ),
      SizedBox(
        width: 160,
        child: SakalFieldCard(
          label: 'Currency',
          required: true,
          editable: !_locked,
          child: DropdownButtonFormField<String>(
            // key: ValueKey(_currencyId) — this dropdown's value changes both
            // via its own onChanged AND externally (_onSupplierSelected
            // auto-picks the supplier's default currency); a FormField's
            // initialValue is only read once at first build, so without a
            // changing key the external path wouldn't visually update it —
            // same gotcha already caught and fixed twice this session for
            // SakalAutocomplete (Contra/Expense Voucher account pickers).
            key: ValueKey(_currencyId),
            initialValue: _currencyId,
            isExpanded: true, isDense: true, itemHeight: null,
            decoration: SakalFieldCard.bareDecoration,
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
          label: 'Bill No', required: true, editable: !_locked,
          child: TextFormField(controller: _billNoCtrl, enabled: !_locked, decoration: SakalFieldCard.bareDecoration),
        ),
      ),
      SizedBox(
        width: 170,
        child: InkWell(
          onTap: !_locked
              ? () async {
                  final d = await showDatePicker(context: context, initialDate: _billDate ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime(2100));
                  if (d != null) setState(() => _billDate = d);
                }
              : null,
          child: SakalFieldCard.readOnly(label: 'Bill Date', value: _billDate != null ? _displayDate(_billDate) : '—'),
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
        const Expanded(child: Text('Expense Lines', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
        Text(
          'Net Payable: ${AppNumberFormat.amount(_netPayable, 'INTERNATIONAL')} $_currencyCode',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _netPayable > 0 ? AppColors.positive : AppColors.negative),
        ),
      ]),
      const SizedBox(height: 8),
      for (var i = 0; i < _lines.length; i++) _buildLineCard(_lines[i], i),
      if (_totalAdd > 0 || _totalDeduct > 0)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Expense: ${AppNumberFormat.amount(_totalExpense, 'INTERNATIONAL')}'
            '${_totalAdd > 0 ? '  +  Tax: ${AppNumberFormat.amount(_totalAdd, 'INTERNATIONAL')}' : ''}'
            '${_totalDeduct > 0 ? '  −  Withholding: ${AppNumberFormat.amount(_totalDeduct, 'INTERNATIONAL')}' : ''}'
            '  =  Net: ${AppNumberFormat.amount(_netPayable, 'INTERNATIONAL')} (preview — confirmed at Approve)',
            style: const TextStyle(fontSize: 11, color: AppColors.textSecondary, fontStyle: FontStyle.italic),
          ),
        ),
    ]);
  }

  Widget _buildLineCard(_ExpenseLineRow row, int index) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(
            width: 300,
            child: SakalFieldCard(
              label: 'Expense Account',
              required: true,
              editable: !_locked,
              child: FinanceAccountPicker(
                key: ValueKey(row.accountDisplay),
                accounts: _expenseAccounts,
                initialValue: row.accountDisplay.isEmpty ? null : row.accountDisplay,
                enabled: !_locked,
                focusNode: row.accountFocusNode,
                decoration: SakalFieldCard.bareDecoration,
                onSelected: (a) => _onLineAccountSelected(row, a),
              ),
            ),
          ),
          SizedBox(
            width: 130,
            child: SakalFieldCard(
              label: 'Amount',
              required: true,
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
            width: 220,
            child: SakalFieldCard(
              label: 'Tax Group (optional)',
              editable: !_locked,
              child: Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    // Same external-change gotcha as the header Currency
                    // dropdown above — this value is also auto-suggested
                    // from the account's own default_tax_group_id in
                    // _onLineAccountSelected, not only via this dropdown's
                    // own onChanged.
                    key: ValueKey(row.taxGroupId),
                    initialValue: row.taxGroupId,
                    isExpanded: true, isDense: true, itemHeight: null,
                    decoration: SakalFieldCard.bareDecoration,
                    items: [
                      const DropdownMenuItem(value: null, child: Text('None')),
                      ..._taxGroups.map((g) => DropdownMenuItem(value: g['id'] as String, child: Text('${g['group_code']}', overflow: TextOverflow.ellipsis))),
                    ],
                    onChanged: _locked
                        ? null
                        : (v) {
                            if (v == null) {
                              _clearLineTaxGroup(row);
                            } else {
                              final match = _taxGroups.firstWhere((g) => g['id'] == v, orElse: () => const {});
                              if (match.isNotEmpty) _onLineTaxGroupSelected(row, match);
                            }
                          },
                  ),
                ),
              ]),
            ),
          ),
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
      ),
    );
  }
}
