import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/printing/print_engine.dart';
import '../../../../core/printing/print_template_provider.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../domain/repositories/purchase_invoice_repository.dart';
import '../providers/purchase_invoice_providers.dart';

class PurchaseInvoiceEntryScreen extends ConsumerStatefulWidget {
  final String? editInvoiceNo;
  final String? editInvoiceDate;
  const PurchaseInvoiceEntryScreen({super.key, this.editInvoiceNo, this.editInvoiceDate});

  @override
  ConsumerState<PurchaseInvoiceEntryScreen> createState() => _PurchaseInvoiceEntryScreenState();
}

class _PurchaseInvoiceEntryScreenState extends ConsumerState<PurchaseInvoiceEntryScreen>
    with ScreenPermissionMixin<PurchaseInvoiceEntryScreen> {
  // Entry screen is not itself a menu item — Menu -> List -> Entry pattern.
  @override String get screenName => RouteNames.purchaseInvoices;

  PurchaseInvoiceRepository get _ds => ref.read(purchaseInvoiceRepositoryProvider);

  // ── Header state ─────────────────────────────────────────────────────────
  String?  _invoiceNo;
  DateTime _invoiceDate = DateTime.now();
  String   _status      = 'DRAFT';
  String?  _locationId;

  String?  _supplierId;
  String?  _supplierDisplay;
  final _supplierInvoiceNoCtrl = TextEditingController();
  DateTime? _supplierInvoiceDate;

  String?  _invoiceCurrencyId;
  String?  _invoiceCurrencyCode;
  final _rateToBaseCtrl  = TextEditingController(text: '1');
  final _rateToLocalCtrl = TextEditingController(text: '1');
  double   get _rateToBase  => double.tryParse(_rateToBaseCtrl.text) ?? 1;
  double   get _rateToLocal => double.tryParse(_rateToLocalCtrl.text) ?? 1;

  final _taxableAmountCtrl = TextEditingController(text: '0');
  final _taxAmountCtrl     = TextEditingController(text: '0');
  double get _taxableAmount => double.tryParse(_taxableAmountCtrl.text) ?? 0;
  double get _taxAmount     => double.tryParse(_taxAmountCtrl.text) ?? 0;
  final _remarksCtrl = TextEditingController();

  // ── GRN picker ────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _suppliers    = [];
  List<Map<String, dynamic>> _pendingGrns  = [];
  final Set<String> _selectedGrnKeys = {};

  String _grnKey(Map<String, dynamic> g) => '${g['grn_no']}|${g['grn_date']}';

  bool    _loading = true;
  String? _error;
  String? _actionError;
  bool    _saving   = false;
  bool    _approving = false;
  bool    _loadingGrns = false;
  bool    _recomputing = false;

  // ── Posted Journal Entries (GRN entry screen's own pattern) ───────────────
  String? _postedVoucherNo;
  String? _postedVoucherDate;
  List<Map<String, dynamic>> _voucherLines = [];
  bool    _loadingVoucherLines = false;

  // ── Print ─────────────────────────────────────────────────────────────────
  bool _printing = false;

  bool get _isNew => _invoiceNo == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _supplierInvoiceNoCtrl.dispose();
    _rateToBaseCtrl.dispose();
    _rateToLocalCtrl.dispose();
    _taxableAmountCtrl.dispose();
    _taxAmountCtrl.dispose();
    _remarksCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      _locationId = session.locationId;
      _suppliers = await _ds.getSuppliersWithPendingGrns(
          clientId: session.clientId, companyId: session.companyId);

      if (widget.editInvoiceNo != null) {
        final header = await _ds.getHeader(
          clientId: session.clientId, companyId: session.companyId,
          invoiceNo: widget.editInvoiceNo!, invoiceDate: widget.editInvoiceDate,
        );
        if (header != null) {
          _invoiceNo           = header.invoiceNo;
          _invoiceDate         = DateTime.parse(header.invoiceDate);
          _status              = header.status;
          _locationId          = header.locationId;
          _supplierId          = header.supplierId;
          _supplierDisplay     = header.supplierName != null ? '[${header.supplierCode}] ${header.supplierName}' : '';
          _supplierInvoiceNoCtrl.text = header.supplierInvoiceNo;
          _supplierInvoiceDate = DateTime.parse(header.supplierInvoiceDate);
          _invoiceCurrencyId   = header.invoiceCurrencyId;
          _invoiceCurrencyCode = header.invoiceCurrencyCode;
          _rateToBaseCtrl.text  = header.rateToBase.toString();
          _rateToLocalCtrl.text = header.rateToLocal.toString();
          _taxableAmountCtrl.text = header.taxableAmount.toString();
          _taxAmountCtrl.text     = header.taxAmount.toString();
          _remarksCtrl.text    = header.remarks ?? '';
          _postedVoucherNo     = header.postedVoucherNo;
          _postedVoucherDate   = header.postedVoucherDate;

          if (_supplierId != null) {
            _pendingGrns = await _ds.getPendingGrnsForSupplier(
              clientId: session.clientId, companyId: session.companyId,
              supplierId: _supplierId!, excludeInvoiceNo: _invoiceNo,
            );
            _selectedGrnKeys.addAll(_pendingGrns
                .where((g) => g['billed_invoice_no'] == _invoiceNo)
                .map(_grnKey));
          }
        }
      }
      if (mounted) setState(() => _loading = false);
      if (_postedVoucherNo != null && _postedVoucherDate != null) {
        unawaited(_loadPostedVoucherLines());
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load: $e'; });
    }
  }

  Future<void> _loadPostedVoucherLines() async {
    if (_postedVoucherNo == null || _postedVoucherDate == null) return;
    setState(() => _loadingVoucherLines = true);
    final session = ref.read(sessionProvider)!;
    try {
      final lines = await _ds.getPostedVoucherLines(
        clientId: session.clientId, companyId: session.companyId,
        voucherNo: _postedVoucherNo!, voucherDate: _postedVoucherDate!,
      );
      if (mounted) setState(() { _voucherLines = lines; _loadingVoucherLines = false; });
    } catch (e) {
      if (mounted) setState(() => _loadingVoucherLines = false);
    }
  }

  // ── Supplier selection ────────────────────────────────────────────────────

  Future<void> _onSupplierSelected(Map<String, dynamic> supplier) async {
    setState(() {
      _supplierId      = supplier['id'] as String;
      _supplierDisplay = '[${supplier['account_code']}] ${supplier['account_name']}';
      _selectedGrnKeys.clear();
      _invoiceCurrencyId   = null;
      _invoiceCurrencyCode = null;
      _pendingGrns = [];
      _loadingGrns = true;
    });
    final session = ref.read(sessionProvider)!;
    try {
      final rows = await _ds.getPendingGrnsForSupplier(
        clientId: session.clientId, companyId: session.companyId,
        supplierId: _supplierId!, excludeInvoiceNo: _invoiceNo,
      );
      if (mounted) setState(() { _pendingGrns = rows; _loadingGrns = false; });
    } catch (e) {
      if (mounted) { setState(() => _loadingGrns = false); _showSnack('Could not load pending GRNs: $e', color: AppColors.negative); }
    }
  }

  // ── GRN checkbox toggle ───────────────────────────────────────────────────

  Future<void> _toggleGrn(Map<String, dynamic> grn, bool checked) async {
    final key = _grnKey(grn);
    setState(() {
      if (checked) {
        _selectedGrnKeys.add(key);
        // First GRN checked locks the bill's currency + defaults its rate —
        // same "inherit, don't re-fetch" precedent as GRN inheriting the PO's
        // own rate.
        if (_invoiceCurrencyId == null) {
          _invoiceCurrencyId   = grn['grn_currency_id'] as String?;
          final currency = grn['currency'] as Map<String, dynamic>?;
          _invoiceCurrencyCode = currency?['currency_id'] as String?;
          _rateToBaseCtrl.text  = (grn['rate_to_base']  as num? ?? 1).toString();
          _rateToLocalCtrl.text = (grn['rate_to_local'] as num? ?? 1).toString();
        }
      } else {
        _selectedGrnKeys.remove(key);
        if (_selectedGrnKeys.isEmpty) { _invoiceCurrencyId = null; _invoiceCurrencyCode = null; }
      }
    });
    await _recomputeDefaults();
  }

  List<Map<String, dynamic>> get _selectableGrns => _invoiceCurrencyId == null
      ? _pendingGrns
      : _pendingGrns.where((g) => g['grn_currency_id'] == _invoiceCurrencyId).toList();

  /// Refreshes the suggested taxable/tax amounts from the currently-checked
  /// GRNs — reads the exact same sums the backend will post, so the user
  /// just validates against the supplier's paper invoice and only edits on
  /// a genuine mismatch.
  Future<void> _recomputeDefaults() async {
    if (_selectedGrnKeys.isEmpty) {
      setState(() { _taxableAmountCtrl.text = '0'; _taxAmountCtrl.text = '0'; });
      return;
    }
    setState(() => _recomputing = true);
    final session = ref.read(sessionProvider)!;
    final refs = _pendingGrns.where((g) => _selectedGrnKeys.contains(_grnKey(g))).map((g) => {
      'grn_no':   g['grn_no'] as String,
      'grn_date': g['grn_date'] as String,
    }).toList();
    try {
      final defaults = await _ds.getGrnBillingDefaults(
        clientId: session.clientId, companyId: session.companyId, grnRefs: refs);
      if (mounted) {
        setState(() {
          _taxableAmountCtrl.text = defaults['taxable_amount']!.toStringAsFixed(2);
          _taxAmountCtrl.text     = defaults['tax_amount']!.toStringAsFixed(2);
          _recomputing = false;
        });
      }
    } catch (e) {
      if (mounted) { setState(() => _recomputing = false); _showSnack('Could not compute totals: $e', color: AppColors.negative); }
    }
  }

  // ── Save / Approve ────────────────────────────────────────────────────────

  Future<void> _saveDraft() async {
    if (_supplierId == null) { _showSnack('Select a supplier.', color: AppColors.negative); return; }
    if (_selectedGrnKeys.isEmpty) { _showSnack('Select at least one GRN.', color: AppColors.negative); return; }
    if (_supplierInvoiceNoCtrl.text.trim().isEmpty) { _showSnack('Enter the supplier\'s invoice number.', color: AppColors.negative); return; }
    if (_supplierInvoiceDate == null) { _showSnack('Enter the supplier\'s invoice date.', color: AppColors.negative); return; }

    setState(() { _saving = true; _actionError = null; });
    final session = ref.read(sessionProvider)!;
    final refs = _pendingGrns.where((g) => _selectedGrnKeys.contains(_grnKey(g))).map((g) => {
      'grn_no':   g['grn_no'] as String,
      'grn_date': g['grn_date'] as String,
    }).toList();
    try {
      final invoiceNo = await _ds.save(
        header: {
          'client_id':             session.clientId,
          'company_id':            session.companyId,
          'location_id':           _locationId,
          'invoice_no':            _invoiceNo,
          'invoice_date':          _fmtDate(_invoiceDate),
          'supplier_id':           _supplierId,
          'supplier_invoice_no':   _supplierInvoiceNoCtrl.text.trim(),
          'supplier_invoice_date': _fmtDate(_supplierInvoiceDate!),
          'invoice_currency_id':   _invoiceCurrencyId,
          'rate_to_base':          _rateToBase,
          'rate_to_local':         _rateToLocal,
          'taxable_amount':        _taxableAmount,
          'tax_amount':            _taxAmount,
          'invoice_total':         _taxableAmount + _taxAmount,
          'remarks':               _remarksCtrl.text.trim(),
        },
        grnRefs: refs,
        userId: session.userId,
      );
      if (mounted) {
        setState(() { _invoiceNo = invoiceNo; _saving = false; });
        _showSnack('Purchase Bill $invoiceNo saved.', color: AppColors.positive);
      }
    } on DioException catch (e) {
      setState(() { _saving = false; _actionError = e.response?.data?['message'] ?? _serverError(e); });
    } catch (e) {
      setState(() { _saving = false; _actionError = 'Unexpected error: $e'; });
    }
  }

  Future<void> _approveInvoice() async {
    if (_invoiceNo == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Approve Purchase Bill'),
        content: const Text('Once approved, the Purchase Accrual clearing, Input VAT and Supplier payable will be '
            'posted to Finance and this bill can no longer be edited. Continue?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.secondary),
            child: const Text('Approve'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() { _approving = true; _actionError = null; });
    final session = ref.read(sessionProvider)!;
    try {
      await _ds.approve(
        clientId: session.clientId, companyId: session.companyId,
        invoiceNo: _invoiceNo!, invoiceDate: _fmtDate(_invoiceDate), approvedBy: session.userId,
      );
      if (mounted) {
        _showSnack('Purchase Bill $_invoiceNo approved.', color: AppColors.positive);
        await _init();
      }
    } on DioException catch (e) {
      setState(() { _approving = false; _actionError = e.response?.data?['message'] ?? _serverError(e); });
    } catch (e) {
      setState(() { _approving = false; _actionError = 'Unexpected error: $e'; });
    }
  }

  String _serverError(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['message'] is String) return data['message'] as String;
    return e.message ?? e.toString();
  }

  // ── Print ─────────────────────────────────────────────────────────────────

  Map<String, dynamic> _buildPrintDocument(Map<String, dynamic> company) {
    final linkedGrns = _pendingGrns.where((g) => _selectedGrnKeys.contains(_grnKey(g)));
    return {
      'company': company,
      'header': {
        'invoice_no':            _invoiceNo ?? '',
        'invoice_date':          _displayDate(_invoiceDate),
        'status':                _status,
        'supplier_name':         _supplierDisplay ?? '',
        'currency_code':         _invoiceCurrencyCode ?? '',
        'supplier_invoice_no':   _supplierInvoiceNoCtrl.text,
        'supplier_invoice_date': _displayDate(_supplierInvoiceDate),
        'remarks':               _remarksCtrl.text,
      },
      'grns': linkedGrns.map((g) {
        final currency = g['currency'] as Map<String, dynamic>?;
        return {
          'grn_no':        g['grn_no'] as String? ?? '',
          'grn_date':      g['grn_date'] as String? ?? '',
          'currency_code': currency?['currency_id'] as String? ?? '',
        };
      }).toList(),
      'totals': {
        'taxable_amount': _taxableAmount,
        'tax_amount':     _taxAmount,
        'invoice_total':  _taxableAmount + _taxAmount,
      },
    };
  }

  Future<void> _printInvoice() async {
    if (_invoiceNo == null) return;
    setState(() => _printing = true);
    try {
      final company  = await ref.read(companyDetailsProvider.future) ?? <String, dynamic>{};
      final template = await ref.read(printTemplateProvider('PURCHASE_INVOICE').future);
      final document = _buildPrintDocument(company);
      await PrintEngine.printDocument(template: template, document: document, filename: '$_invoiceNo.pdf');
    } catch (e) {
      if (mounted) _showSnack('Print failed: $e', color: AppColors.negative);
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  Widget _buildPrintButton() => Tooltip(
    message: _printing ? 'Preparing PDF…' : 'Print / Save as PDF',
    child: IconButton(
      icon: _printing
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.print_outlined),
      color: AppColors.primary,
      onPressed: _printing ? null : _printInvoice,
    ),
  );

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _fmtDate(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _displayDate(DateTime? d) {
    if (d == null) return 'Select date';
    const m = ['', 'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day.toString().padLeft(2, '0')} ${m[d.month]} ${d.year}';
  }

  void _showSnack(String msg, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  Future<void> _pickDate(DateTime? current, ValueChanged<DateTime> onPicked) async {
    final d = await showDatePicker(context: context, initialDate: current ?? DateTime.now(),
        firstDate: DateTime(2020), lastDate: DateTime(2099));
    if (d != null) onPicked(d);
  }

  static Widget _req(String text) => RichText(
    text: TextSpan(
      text: text,
      style: const TextStyle(color: AppColors.textSecondary, fontSize: 14, fontWeight: FontWeight.w400),
      children: const [
        TextSpan(text: ' *', style: TextStyle(color: AppColors.negative, fontWeight: FontWeight.w600)),
      ],
    ),
  );

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final session   = ref.watch(sessionProvider);
    final isOffline = session?.offlineMode ?? false;
    final isMobile  = Responsive.isMobile(context);

    final canSave     = !isOffline && _status == 'DRAFT' && (_isNew ? canAdd : canEdit);
    final showApprove = !isOffline && _status == 'DRAFT' && canApprove && !_isNew;
    final locked      = _status != 'DRAFT';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isOffline) const OfflineBanner(),

        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: isMobile
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _buildTitleBlock(),
                  if (_invoiceNo != null || canSave || showApprove) ...[
                    const SizedBox(height: 10),
                    Row(children: [
                      if (_invoiceNo != null) _buildPrintButton(),
                      if (canSave || showApprove) _buildActionButtons(canSave: canSave, canApprove: showApprove),
                    ]),
                  ],
                ])
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _buildTitleBlock()),
                  if (_invoiceNo != null) _buildPrintButton(),
                  if (canSave || showApprove) _buildActionButtons(canSave: canSave, canApprove: showApprove),
                ]),
        ),

        const Divider(height: 20),

        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : isOffline
                  ? _offlineNotice()
                  : SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_error != null) ...[_errorBanner(_error!, onRetry: _init), const SizedBox(height: 16)],
                          if (_actionError != null) ...[_errorBanner(_actionError!), const SizedBox(height: 16)],
                          _buildHeaderCard(locked, isMobile),
                          const SizedBox(height: 16),
                          _buildGrnPickerCard(locked),
                          const SizedBox(height: 16),
                          _buildTotalsCard(locked),
                          if (_status == 'APPROVED' && _postedVoucherNo != null) ...[
                            const SizedBox(height: 16),
                            _buildPostedVoucherSection(),
                          ],
                        ],
                      ),
                    ),
        ),
      ],
    );
  }

  Widget _offlineNotice() => const Center(
    child: Padding(
      padding: EdgeInsets.all(24),
      child: Text('Purchase Bill needs a live connection — it checks GRNs\' current billing status in real time.',
          textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
    ),
  );

  Widget _buildTitleBlock() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(_invoiceNo != null ? 'Purchase Bill · $_invoiceNo' : 'New Purchase Bill',
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
    const SizedBox(height: 2),
    _status == 'APPROVED'
        ? _statusChip(_status)
        : Text(_invoiceNo != null ? 'Draft' : 'Unsaved draft',
            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
  ]);

  Widget _statusChip(String status) {
    final color = status == 'APPROVED' ? AppColors.positive : AppColors.secondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
      child: Text(status, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    );
  }

  Widget _buildActionButtons({required bool canSave, required bool canApprove}) => Row(children: [
    if (canSave) FilledButton(
      onPressed: _saving ? null : _saveDraft,
      child: _saving
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          : const Text('Save Draft'),
    ),
    if (canSave && canApprove) const SizedBox(width: 12),
    if (canApprove) FilledButton(
      onPressed: _approving ? null : _approveInvoice,
      style: FilledButton.styleFrom(backgroundColor: AppColors.secondary),
      child: _approving
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          : const Text('Approve'),
    ),
  ]);

  Widget _errorBanner(String msg, {VoidCallback? onRetry}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: AppColors.negative.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: AppColors.negative.withValues(alpha: 0.3)),
    ),
    child: Row(children: [
      const Icon(Icons.error_outline, color: AppColors.negative, size: 18),
      const SizedBox(width: 10),
      Expanded(child: Text(msg, style: const TextStyle(fontSize: 13, color: AppColors.negative))),
      if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Retry')),
    ]),
  );

  // ── Header card ───────────────────────────────────────────────────────────

  Widget _buildHeaderCard(bool locked, bool isMobile) {
    const fh = 56.0;
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10));
    Widget field(Widget child) => SizedBox(height: fh, child: child);
    final supplierLocked = locked || _selectedGrnKeys.isNotEmpty;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          // Row 1: Supplier | Bill No | Bill Date
          Builder(builder: (_) {
            final f1 = SizedBox(
              height: fh,
              child: Autocomplete<Map<String, dynamic>>(
                key: ValueKey(_supplierDisplay ?? ''),
                initialValue: TextEditingValue(text: _supplierDisplay ?? ''),
                displayStringForOption: (s) => '[${s['account_code']}] ${s['account_name']}',
                optionsBuilder: (v) {
                  if (supplierLocked) return const [];
                  final q = v.text.toLowerCase().trim();
                  return q.isEmpty ? _suppliers : _suppliers.where((s) =>
                      (s['account_code'] as String? ?? '').toLowerCase().contains(q) ||
                      (s['account_name'] as String? ?? '').toLowerCase().contains(q));
                },
                onSelected: (s) => _onSupplierSelected(s),
                fieldViewBuilder: (context, textCtrl, focusNode, onFieldSubmitted) => TextFormField(
                  controller: textCtrl, focusNode: focusNode, enabled: !supplierLocked,
                  decoration: dec.copyWith(labelText: 'Supplier *',
                      helperText: supplierLocked && !locked ? 'Locked once a GRN is picked' : null,
                      helperStyle: const TextStyle(fontSize: 10)),
                  style: const TextStyle(fontSize: 13),
                ),
                optionsViewBuilder: (context, onSel, opts) => Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    elevation: 4,
                    borderRadius: BorderRadius.circular(4),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 260, minWidth: 260),
                      child: ListView.builder(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        itemCount: opts.length,
                        itemBuilder: (context, idx) {
                          final s = opts.elementAt(idx);
                          return InkWell(
                            onTap: () => onSel(s),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              child: Text('[${s['account_code']}] ${s['account_name']}', style: const TextStyle(fontSize: 13)),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            );
            final f2 = field(InputDecorator(
              decoration: dec.copyWith(labelText: 'Bill No'),
              child: Text(_invoiceNo ?? '(auto on save)',
                  style: TextStyle(fontSize: 13, color: _invoiceNo != null ? AppColors.textPrimary : AppColors.textDisabled)),
            ));
            final f3 = field(InkWell(
              onTap: locked ? null : () => _pickDate(_invoiceDate, (d) => setState(() => _invoiceDate = d)),
              child: InputDecorator(
                decoration: dec.copyWith(labelText: 'Bill Date *',
                    suffixIcon: Icon(Icons.calendar_today_outlined, size: 15,
                        color: locked ? AppColors.textDisabled : AppColors.primary)),
                child: Text(_displayDate(_invoiceDate), style: const TextStyle(fontSize: 13)),
              ),
            ));
            return isMobile
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: double.infinity, child: f1), const SizedBox(height: 8),
                    Row(children: [Expanded(child: f2), const SizedBox(width: 12), Expanded(child: f3)]),
                  ])
                : Row(children: [
                    Expanded(flex: 3, child: f1), const SizedBox(width: 12),
                    Expanded(flex: 2, child: f2), const SizedBox(width: 12),
                    Expanded(flex: 2, child: f3),
                  ]);
          }),
          const SizedBox(height: 12),

          // Row 2: Supplier Invoice No | Supplier Invoice Date
          Builder(builder: (_) {
            final f1 = field(TextFormField(
              controller: _supplierInvoiceNoCtrl, enabled: !locked,
              decoration: dec.copyWith(label: _req('Supplier Invoice No')),
              style: const TextStyle(fontSize: 13),
              onChanged: (_) => setState(() {}),
            ));
            final f2 = field(InkWell(
              onTap: locked ? null : () => _pickDate(_supplierInvoiceDate, (d) => setState(() => _supplierInvoiceDate = d)),
              child: InputDecorator(
                decoration: dec.copyWith(label: _req('Supplier Invoice Date'),
                    suffixIcon: Icon(Icons.calendar_today_outlined, size: 15,
                        color: locked ? AppColors.textDisabled : AppColors.primary)),
                child: Text(_displayDate(_supplierInvoiceDate),
                    style: TextStyle(fontSize: 13, color: _supplierInvoiceDate == null ? AppColors.textDisabled : null)),
              ),
            ));
            return isMobile
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: double.infinity, child: f1), const SizedBox(height: 8),
                    SizedBox(width: double.infinity, child: f2),
                  ])
                : Row(children: [Expanded(child: f1), const SizedBox(width: 12), Expanded(child: f2)]);
          }),
          const SizedBox(height: 12),

          // Row 3: Currency (locked, inherited from GRNs) | Rate -> Base | Rate -> Local
          Builder(builder: (_) {
            final currAsync = ref.watch(currenciesProvider);
            return currAsync.when(
              data: (currencies) {
                final selectedCurrency = currencies.where((c) => c['id'] == _invoiceCurrencyId).firstOrNull;
                final f1 = field(InputDecorator(
                  decoration: dec.copyWith(labelText: 'Currency',
                      helperText: 'Inherited from the selected GRN(s)', helperStyle: const TextStyle(fontSize: 10)),
                  child: Text(
                    selectedCurrency != null ? '${selectedCurrency['currency_id']} — ${selectedCurrency['currency_name']}' : '—',
                    style: const TextStyle(fontSize: 13)),
                ));
                final f2 = field(TextFormField(
                  controller: _rateToBaseCtrl, enabled: !locked,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: dec.copyWith(labelText: 'Rate → Base'),
                  style: const TextStyle(fontSize: 13),
                  onChanged: (_) => setState(() {}),
                ));
                final f3 = field(TextFormField(
                  controller: _rateToLocalCtrl, enabled: !locked,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: dec.copyWith(labelText: 'Rate → Local'),
                  style: const TextStyle(fontSize: 13),
                  onChanged: (_) => setState(() {}),
                ));
                return isMobile
                    ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        SizedBox(width: double.infinity, child: f1), const SizedBox(height: 8),
                        Row(children: [Expanded(child: f2), const SizedBox(width: 12), Expanded(child: f3)]),
                      ])
                    : Row(children: [
                        Expanded(flex: 2, child: f1), const SizedBox(width: 12),
                        Expanded(flex: 2, child: f2), const SizedBox(width: 12),
                        Expanded(flex: 2, child: f3),
                      ]);
              },
              loading: () => const SizedBox(height: fh, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
              error: (e, _) => Text('Could not load currencies: $e'),
            );
          }),
        ]),
      ),
    );
  }

  // ── GRN picker card ───────────────────────────────────────────────────────

  Widget _buildGrnPickerCard(bool locked) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Pending GRNs', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          if (_supplierId == null)
            const Text('Select a supplier to see their approved, not-yet-billed GRNs.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary))
          else if (_loadingGrns)
            const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
          else if (_selectableGrns.isEmpty)
            const Text('No pending GRNs for this supplier.', style: TextStyle(fontSize: 12, color: AppColors.textSecondary))
          else
            ..._selectableGrns.map((g) {
              final key = _grnKey(g);
              final currency = g['currency'] as Map<String, dynamic>?;
              return CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _selectedGrnKeys.contains(key),
                onChanged: locked ? null : (v) => _toggleGrn(g, v ?? false),
                title: Text(g['grn_no'] as String, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                subtitle: Text(
                    '${g['grn_date']} · ${currency?['currency_id'] ?? ''}',
                    style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
              );
            }),
        ]),
      ),
    );
  }

  // ── Totals card ───────────────────────────────────────────────────────────

  Widget _buildTotalsCard(bool locked) {
    const fh = 56.0;
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10));
    Widget field(Widget child) => SizedBox(height: fh, child: child);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('Amounts', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            const SizedBox(width: 8),
            if (_recomputing) const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
          const SizedBox(height: 4),
          const Text('Auto-filled from the selected GRN(s) — validate against the supplier\'s paper invoice and edit only if it differs.',
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 12, children: [
            SizedBox(width: 220, child: field(TextFormField(
              controller: _taxableAmountCtrl, enabled: !locked,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: dec.copyWith(labelText: 'Taxable Amount'),
              style: const TextStyle(fontSize: 13),
              onChanged: (_) => setState(() {}),
            ))),
            SizedBox(width: 220, child: field(TextFormField(
              controller: _taxAmountCtrl, enabled: !locked,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: dec.copyWith(labelText: 'VAT / Tax Amount'),
              style: const TextStyle(fontSize: 13),
              onChanged: (_) => setState(() {}),
            ))),
            SizedBox(width: 220, child: field(InputDecorator(
              decoration: dec.copyWith(labelText: 'Invoice Total'),
              child: Text('${_invoiceCurrencyCode ?? ''} ${(_taxableAmount + _taxAmount).toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            ))),
          ]),
          const SizedBox(height: 12),
          TextFormField(controller: _remarksCtrl, enabled: !locked, maxLines: 2,
              decoration: dec.copyWith(labelText: 'Remarks'), style: const TextStyle(fontSize: 13)),
        ]),
      ),
    );
  }

  // ── Posted Journal Entries — same pattern as GRN entry screen ────────────

  Widget _buildPostedVoucherSection() {
    Widget colHeader(String label, {TextAlign align = TextAlign.left}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Text(label, textAlign: align,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12)),
    );
    Widget cell(String text, {TextAlign align = TextAlign.left, bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Text(text, textAlign: align,
          style: TextStyle(fontSize: 13, fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
    );

    double totalDebit = 0, totalCredit = 0;
    for (final l in _voucherLines) {
      final amount = (l['trans_amount'] as num? ?? 0).toDouble();
      if (l['trans_nature'] == 'DR') { totalDebit += amount; } else { totalCredit += amount; }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Text('Posted Journal Entries',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: AppColors.positive.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
            child: Text(_postedVoucherNo ?? '', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.positive)),
          ),
        ]),
        const SizedBox(height: 8),
        if (_loadingVoucherLines)
          const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
        else if (_voucherLines.isEmpty)
          const Padding(padding: EdgeInsets.all(16), child: Text('No journal entry lines found for this voucher.'))
        else
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              Container(
                color: AppColors.primary,
                child: Row(children: [
                  Expanded(flex: 3, child: colHeader('Voucher No')),
                  Expanded(flex: 2, child: colHeader('Serial No')),
                  Expanded(flex: 4, child: colHeader('Ledger Name')),
                  Expanded(flex: 2, child: colHeader('Debit', align: TextAlign.right)),
                  Expanded(flex: 2, child: colHeader('Credit', align: TextAlign.right)),
                ]),
              ),
              for (var i = 0; i < _voucherLines.length; i++) Builder(builder: (_) {
                final l = _voucherLines[i];
                final account = l['account'] as Map<String, dynamic>?;
                final ledgerName = account != null ? '[${account['account_code']}] ${account['account_name']}' : '—';
                final amount = (l['trans_amount'] as num? ?? 0).toDouble();
                final isDr = l['trans_nature'] == 'DR';
                return Container(
                  color: i.isEven ? Colors.white : AppColors.background,
                  child: Row(children: [
                    Expanded(flex: 3, child: cell(l['trans_no'] as String? ?? '')),
                    Expanded(flex: 2, child: cell('${l['serial_no']}')),
                    Expanded(flex: 4, child: cell(ledgerName)),
                    Expanded(flex: 2, child: cell(isDr ? amount.toStringAsFixed(2) : '—', align: TextAlign.right)),
                    Expanded(flex: 2, child: cell(!isDr ? amount.toStringAsFixed(2) : '—', align: TextAlign.right)),
                  ]),
                );
              }),
              Container(
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.06),
                  border: const Border(top: BorderSide(color: AppColors.border)),
                ),
                child: Row(children: [
                  const Expanded(flex: 9, child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Text('Total', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                  )),
                  Expanded(flex: 2, child: cell(totalDebit.toStringAsFixed(2), align: TextAlign.right, bold: true)),
                  Expanded(flex: 2, child: cell(totalCredit.toStringAsFixed(2), align: TextAlign.right, bold: true)),
                ]),
              ),
            ]),
          ),
      ],
    );
  }
}
