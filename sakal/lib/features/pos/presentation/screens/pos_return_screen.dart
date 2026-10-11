import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/printing/print_engine.dart';
import '../../../../core/printing/print_models.dart';
import '../../../../core/printing/print_template_provider.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../sales/presentation/providers/sales_return_providers.dart';
import '../widgets/pos_keyboard.dart';
import '../widgets/pos_qty_stepper.dart';

const _posReturnReasons = ['Damaged', 'Wrong product', 'Customer changed mind', 'Quality issue', 'Expired', 'Duplicate purchase', 'Pricing issue', 'Other'];

class _ReturnableLine {
  final int invoiceLineSerial;
  final String productId;
  final String productName;
  final String uomId;
  final double uomConversionFactor;
  final String? taxGroupId;
  final double rate;
  final double soldQty;
  final double alreadyReturned;
  final bool isTracked;
  double returnQty = 0;

  // The ORIGINAL invoice line's own stored amounts — already net of any
  // scheme/promo discount applied at sale time (e.g. "buy 2 get 1 free").
  // Real bug fixed 2026-10-11: this screen used to recompute
  // `returnQty * rate` from scratch, ignoring any discount entirely —
  // refunding MORE than the customer ever paid whenever a promo applied.
  // Fix mirrors the back-office Sales Return screen's own proven approach
  // (sales_return_entry_screen.dart's _SRLineRow): derive the return
  // line's own amounts as a proportion of what this invoice line actually
  // totaled, never by recomputing from unit rate.
  final double invoiceGrossAmount;
  final double invoiceTaxAmount;
  final double invoiceFinalAmount;

  double get remaining => soldQty - alreadyReturned;
  double get _fraction => soldQty > 0 ? returnQty / soldQty : 0;
  double get grossAmount => invoiceGrossAmount * _fraction;
  double get taxAmount => invoiceTaxAmount * _fraction;
  double get finalAmount => invoiceFinalAmount * _fraction;

  _ReturnableLine({
    required this.invoiceLineSerial,
    required this.productId,
    required this.productName,
    required this.uomId,
    required this.uomConversionFactor,
    required this.taxGroupId,
    required this.rate,
    required this.soldQty,
    required this.alreadyReturned,
    required this.isTracked,
    required this.invoiceGrossAmount,
    required this.invoiceTaxAmount,
    required this.invoiceFinalAmount,
  });
}

/// Return at the till — reuses the EXISTING Sales Return engine
/// (fn_save_sales_return/fn_approve_sales_return, migration 099) unchanged,
/// per docs/pos/05_returns_exchange_void_approvals.md's own design: "POS
/// return — reuses the existing Sales Return engine, not new logic."
///
/// v1 scope cut, consistent with New Sale's own: batch/serial-tracked lines
/// are shown but not selectable (New Sale never creates a tracked-product
/// POS line in the first place, so this mostly matters for a POS return
/// against a BACK-OFFICE invoice that does have tracked lines — shown,
/// disabled, with a note). Auto-approves immediately after save (one
/// "Refund" button), matching New Sale's own "Save IS Approve" POS pace —
/// unlike the back-office Sales Return screen's deliberate two-step Save/
/// Approve split.
class PosReturnScreen extends ConsumerStatefulWidget {
  const PosReturnScreen({super.key});

  @override
  ConsumerState<PosReturnScreen> createState() => _PosReturnScreenState();
}

class _PosReturnScreenState extends ConsumerState<PosReturnScreen> {
  final _searchCtrl = TextEditingController();
  bool _searching = false;
  bool _saving = false;
  String? _error;
  String? _actionError;

  Map<String, dynamic>? _invoice;
  final List<_ReturnableLine> _lines = [];
  String _reason = _posReturnReasons.first;

  DateTime _selectedDate = DateTime.now();
  bool _loadingRecent = false;
  List<Map<String, dynamic>> _recentInvoices = [];

  // ── Receipt printing (ric_pos_terminals.receipt_*, migration 217) ────────
  String? _receiptPaperProfile;
  String? _receiptPrinterUrl;

  bool get _showRefund => _invoice != null && _invoice!['sale_type'] == 'CASH' && _invoice!['cash_collection_mode'] == 'IMMEDIATE';

  double get _taxableTotal => _lines.fold(0, (s, l) => s + l.grossAmount);
  double get _taxTotal => _lines.fold(0, (s, l) => s + l.taxAmount);
  double get _returnTotal => _taxableTotal + _taxTotal;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadRecentInvoices();
      _loadTerminalPrintConfig();
    });
  }

  Future<void> _loadTerminalPrintConfig() async {
    final terminalId = ref.read(sessionProvider)?.posTerminalId;
    if (terminalId == null) return;
    try {
      final res = await DioClient.instance.get('/ric_pos_terminals', queryParameters: {
        'id': 'eq.$terminalId', 'select': 'receipt_paper_profile,receipt_printer_url',
      });
      final list = res.data as List;
      if (list.isEmpty || !mounted) return;
      final t = list.first as Map<String, dynamic>;
      setState(() {
        _receiptPaperProfile = t['receipt_paper_profile'] as String?;
        _receiptPrinterUrl = t['receipt_printer_url'] as String?;
      });
    } catch (_) {
      // Printer config is best-effort — falls back to the dialog-based
      // default path if this fetch fails for any reason.
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadRecentInvoices() async {
    final session = ref.read(sessionProvider)!;
    final ds = ref.read(salesReturnRepositoryProvider);
    setState(() => _loadingRecent = true);
    try {
      final rows = await ds.getApprovedInvoices(clientId: session.clientId, companyId: session.companyId, invoiceDate: _fmtDate(_selectedDate));
      if (mounted) setState(() { _recentInvoices = rows; _loadingRecent = false; });
    } catch (e, st) {
      AppLogger.error('PosReturnLoadRecent', e, st);
      if (mounted) setState(() => _loadingRecent = false);
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(context: context, initialDate: _selectedDate, firstDate: DateTime(2020), lastDate: DateTime.now());
    if (picked == null) return;
    setState(() => _selectedDate = picked);
    _loadRecentInvoices();
  }

  /// Partial text is expected here (a cashier typing "0004" should find
  /// "SI/HO/2026/00004") — the datasource already does an `ilike` search;
  /// this used to then throw those results away with an exact `==` check,
  /// which is the real bug a live user report caught ("No approved invoice
  /// found for '0004'" even though it clearly exists). A single match loads
  /// straight through; several matches are shown as a pick list instead of
  /// guessing which one was meant.
  Future<void> _findInvoice(String value) async {
    final invoiceNo = value.trim();
    if (invoiceNo.isEmpty) return;
    final session = ref.read(sessionProvider)!;
    final ds = ref.read(salesReturnRepositoryProvider);
    setState(() { _searching = true; _error = null; _invoice = null; _lines.clear(); });
    try {
      final matches = await ds.getApprovedInvoices(clientId: session.clientId, companyId: session.companyId, search: invoiceNo);
      if (matches.isEmpty) {
        setState(() { _searching = false; _error = 'No approved invoice found for "$invoiceNo".'; });
        return;
      }
      if (matches.length > 1) {
        setState(() { _searching = false; _recentInvoices = matches; });
        return;
      }
      await _loadInvoice(matches.first);
    } catch (e, st) {
      AppLogger.error('PosReturnFind', e, st);
      if (mounted) setState(() { _searching = false; _error = ErrorPresenter.format(e, action: 'find this invoice'); });
    }
  }

  Future<void> _loadInvoice(Map<String, dynamic> invoice) async {
    final session = ref.read(sessionProvider)!;
    final ds = ref.read(salesReturnRepositoryProvider);
    setState(() { _searching = true; _error = null; _invoice = null; _lines.clear(); });
    try {
      _invoice = invoice;
      final invoiceNo = invoice['invoice_no'] as String;
      final invDate = invoice['invoice_date'] as String;

      final lines = await ds.getInvoiceLines(clientId: session.clientId, companyId: session.companyId, invoiceNo: invoiceNo, invoiceDate: invDate);
      final returnedRows = await ds.getAlreadyReturnedByLine(clientId: session.clientId, companyId: session.companyId, invoiceNo: invoiceNo, invoiceDate: invDate);
      final returnedByLine = <int, double>{};
      for (final r in returnedRows) {
        final serial = r['invoice_line_serial'] as int;
        returnedByLine[serial] = (returnedByLine[serial] ?? 0) + ((r['base_qty'] as num?)?.toDouble() ?? 0);
      }

      for (final l in lines) {
        final product = l['product'] as Map<String, dynamic>?;
        _lines.add(_ReturnableLine(
          invoiceLineSerial: l['serial_no'] as int,
          productId: l['product_id'] as String,
          productName: product?['product_name'] as String? ?? '',
          uomId: l['uom_id'] as String,
          uomConversionFactor: (l['uom_conversion_factor'] as num?)?.toDouble() ?? 1,
          taxGroupId: l['tax_group_id'] as String?,
          rate: (l['rate'] as num?)?.toDouble() ?? 0,
          soldQty: (l['base_qty'] as num?)?.toDouble() ?? 0,
          alreadyReturned: returnedByLine[l['serial_no']] ?? 0,
          isTracked: (product?['tracking_type'] as String? ?? 'NONE') != 'NONE',
          invoiceGrossAmount: (l['gross_amount'] as num?)?.toDouble() ?? 0,
          invoiceTaxAmount: (l['tax_amount'] as num?)?.toDouble() ?? 0,
          invoiceFinalAmount: (l['final_amount'] as num?)?.toDouble() ?? 0,
        ));
      }

      setState(() => _searching = false);
    } catch (e, st) {
      AppLogger.error('PosReturnFind', e, st);
      if (mounted) setState(() { _searching = false; _error = ErrorPresenter.format(e, action: 'find this invoice'); });
    }
  }

  Future<void> _submit() async {
    final returnLines = _lines.where((l) => l.returnQty > 0).toList();
    if (returnLines.isEmpty) {
      _showMsg('Enter a return quantity for at least one line.', color: AppColors.negative);
      return;
    }
    final session = ref.read(sessionProvider)!;
    setState(() { _saving = true; _actionError = null; });
    try {
      final header = {
        'client_id': session.clientId,
        'company_id': session.companyId,
        'return_no': null,
        'return_date': _fmtDate(DateTime.now()),
        'invoice_no': _invoice!['invoice_no'],
        'invoice_date': _invoice!['invoice_date'],
        'taxable_amount': _taxableTotal,
        'tax_amount': _taxTotal,
        'charges_amount': 0,
        'return_total': _returnTotal,
        'refund_amount_local': _showRefund ? _returnTotal : 0,
        'refund_amount_base': 0,
        'reason': _reason,
        'remarks': '',
      };
      final lines = returnLines.asMap().entries.map((e) {
        final qty = e.value.returnQty;
        return {
          'serial_no': e.key + 1,
          'invoice_line_serial': e.value.invoiceLineSerial,
          'product_id': e.value.productId,
          'barcode': '',
          'uom_id': e.value.uomId,
          'uom_conversion_factor': e.value.uomConversionFactor,
          'qty_pack': qty,
          'qty_loose': 0,
          'base_qty': qty,
          'rate': e.value.rate,
          'tax_group_id': e.value.taxGroupId,
          // Proportional to this invoice line's own actual totals (see
          // _ReturnableLine's own doc comment) — NOT qty * rate, which
          // ignores any scheme/promo discount applied at sale time.
          'gross_amount': e.value.grossAmount,
          'tax_amount': e.value.taxAmount,
          'final_amount': e.value.finalAmount,
        };
      }).toList();

      final ds = ref.read(salesReturnRepositoryProvider);
      final returnNo = await ds.save(header: header, lines: lines, batches: const [], serials: const [], charges: const [], userId: session.userId);
      final returnDate = header['return_date'] as String;
      await ds.approve(clientId: session.clientId, companyId: session.companyId, returnNo: returnNo, returnDate: returnDate, approvedBy: session.userId);

      if (mounted) {
        _showMsg('$returnNo completed.', color: AppColors.positive);
        // Same "always print, no confirmation" rule as New Sale's own
        // receipt — a refund slip prints automatically every time.
        await _printReceipt(returnNo, returnDate, returnLines);
        if (mounted) await _offerExchange();
      }
    } catch (e, st) {
      AppLogger.error('PosReturnSubmit', e, st);
      if (mounted) setState(() => _actionError = ErrorPresenter.format(e, action: 'complete this return'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// "Exchange" (2026-10-11) is deliberately NOT a new financial primitive
  /// — it's the exact same Return + new Sale this app already does
  /// correctly on its own, just chained with one convenience: the refund
  /// amount just handed back is carried into New Sale as a starting
  /// credit (see PosNewSaleScreen.exchangeCreditAmount) so the cashier
  /// doesn't have to do the "how much more do I collect / hand back"
  /// math themselves, and isn't forced to physically exchange cash twice.
  /// Only offered when a real cash refund was actually processed (credit-
  /// sale returns have no cash amount to carry forward).
  Future<void> _offerExchange() async {
    if (!_showRefund || _returnTotal <= 0) {
      if (mounted) context.go(RouteNames.posSale);
      return;
    }
    if (!mounted) return;
    final startExchange = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Return complete'),
        content: Text('${_returnTotal.toStringAsFixed(2)} refunded. Is the customer exchanging for something else?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Done')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Start Exchange')),
        ],
      ),
    );
    if (!mounted) return;
    if (startExchange == true) {
      context.go(RouteNames.posSale, extra: {'exchangeCreditAmount': _returnTotal});
    } else {
      context.go(RouteNames.posSale);
    }
  }

  // Prints the dedicated narrow 'POS_RETURN_RECEIPT' template, never the
  // back-office 'SALES_RETURN' A4 letterhead layout — same fix as New
  // Sale's own receipt (2026-10-11).
  Future<void> _printReceipt(String returnNo, String returnDate, List<_ReturnableLine> returnLines) async {
    try {
      final company = await ref.read(companyDetailsProvider.future) ?? <String, dynamic>{};
      final baseTemplate = await ref.read(printTemplateProvider('POS_RETURN_RECEIPT').future);
      final template = _receiptPaperProfile == 'RECEIPT_58MM'
          ? PrintTemplate(documentType: baseTemplate.documentType, templateName: baseTemplate.templateName,
              paperProfile: PaperProfile.receipt58mm, isDefault: baseTemplate.isDefault, elements: baseTemplate.elements)
          : baseTemplate;
      final customerName = (_invoice!['customer'] as Map<String, dynamic>?)?['account_name'] as String? ?? 'Walk-in';
      final session = ref.read(sessionProvider);
      final document = {
        'company': company,
        'header': {
          'return_no': returnNo,
          'return_date': returnDate,
          'status': 'APPROVED',
          'invoice_no': _invoice!['invoice_no'],
          'customer_name': customerName,
          'cashier_name': session?.fullName ?? '',
          'currency_code': '',
          'reason': _reason,
          'remarks': '',
          'signatures': {'prepared_by': '', 'authorised_by': ''},
        },
        'lines': returnLines.map((l) => {
          'product_name': l.productName,
          'return_qty': l.returnQty,
          'rate': l.rate,
          'final_amount': l.finalAmount,
        }).toList(),
        'totals': {
          'taxable_amount': _taxableTotal,
          'tax_amount': _taxTotal,
          'return_total': _returnTotal,
        },
      };
      if (!mounted) return;
      await PrintEngine.printDocument(
        template: template,
        document: document,
        filename: '$returnNo.pdf',
        printedByName: session?.fullName,
        printedOn: DateTime.now(),
        directPrint: true,
        printerUrl: _receiptPrinterUrl,
      );
    } catch (e, st) {
      AppLogger.error('PosReturnReceiptPrint', e, st);
      if (mounted) _showMsg('Return saved, but printing the receipt failed: ${ErrorPresenter.format(e, action: 'print this receipt')}', color: AppColors.secondary);
    }
  }

  void _showMsg(String msg, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  String _fmtDate(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary, foregroundColor: Colors.white,
        title: const Text('Return / Refund'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.go(RouteNames.posSale)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_invoice == null) ...[
                // Browse-first: a date picker (default today) + a tappable
                // list of that day's APPROVED invoices — typing an invoice
                // number is kept only as a fallback below, since a cashier
                // on a touchscreen till has no reliable OS keyboard to type
                // one with.
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickDate,
                      icon: const Icon(Icons.calendar_today_outlined, size: 18),
                      label: Text(_fmtDate(_selectedDate)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (_loadingRecent) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                ]),
                const SizedBox(height: 10),
                if (!_loadingRecent && _recentInvoices.isEmpty)
                  const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('No approved invoices for this date.', style: TextStyle(color: AppColors.textSecondary))),
                ..._recentInvoices.map((inv) {
                  final customer = (inv['customer'] as Map<String, dynamic>?)?['account_name'] as String?;
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: const Icon(Icons.receipt_long_outlined, color: AppColors.primary),
                      title: Text(inv['invoice_no'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('${customer ?? 'Walk-in'} · ${inv['sale_type']}'),
                      trailing: Text((inv['grand_total'] as num).toStringAsFixed(2), style: const TextStyle(fontWeight: FontWeight.w800)),
                      onTap: () => _loadInvoice(inv),
                    ),
                  );
                }),
                const SizedBox(height: 14),
                const Text('Or find by invoice number', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(
                    child: PosKeyboardField(
                      label: 'Invoice number…',
                      value: _searchCtrl.text,
                      onChanged: (v) => _searchCtrl.text = v,
                      onConfirmedSubmit: () => _findInvoice(_searchCtrl.text),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(onPressed: _searching ? null : () => _findInvoice(_searchCtrl.text), child: _searching ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Find')),
                ]),
              ],
              if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: const TextStyle(color: AppColors.negative))),
              if (_invoice != null) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => setState(() { _invoice = null; _lines.clear(); _error = null; }),
                    icon: const Icon(Icons.arrow_back, size: 16),
                    label: const Text('Back to invoice list'),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${_invoice!['invoice_no']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                      Text('${_invoice!['invoice_date']} · ${_invoice!['sale_type']} · Total ${(_invoice!['grand_total'] as num).toStringAsFixed(2)}', style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5)),
                    ]),
                  ),
                ),
                const SizedBox(height: 12),
                ..._lines.map((l) => Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(children: [
                          Expanded(
                            flex: 3,
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(l.productName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5), maxLines: 1, overflow: TextOverflow.ellipsis),
                              Text(
                                'Sold ${l.soldQty.toStringAsFixed(0)} · Returned ${l.alreadyReturned.toStringAsFixed(0)} · Remaining ${l.remaining.toStringAsFixed(0)}'
                                '${l.isTracked ? ' · batch/serial not supported here' : ''}',
                                style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                              ),
                            ]),
                          ),
                          SizedBox(
                            width: 140,
                            child: PosQtyStepper(
                              value: l.returnQty,
                              min: 0,
                              enabled: !l.isTracked && l.remaining > 0,
                              onChanged: (v) => setState(() => l.returnQty = v > l.remaining ? l.remaining : v),
                            ),
                          ),
                        ]),
                      ),
                    )),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: _reason,
                  isExpanded: true, isDense: true, itemHeight: null,
                  decoration: const InputDecoration(labelText: 'Reason', border: OutlineInputBorder()),
                  items: _posReturnReasons.map((r) => DropdownMenuItem(value: r, child: Text(r))).toList(),
                  onChanged: (v) => setState(() => _reason = v!),
                ),
                const SizedBox(height: 16),
                Card(
                  color: AppColors.background,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        const Text('Refund Value', style: TextStyle(fontWeight: FontWeight.w700)),
                        Text(_returnTotal.toStringAsFixed(2), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
                      ]),
                      if (!_showRefund)
                        const Padding(
                          padding: EdgeInsets.only(top: 4),
                          child: Text('This invoice was not immediately cash-collected — no cash refund will be paid out from this screen.', style: TextStyle(fontSize: 11.5, color: AppColors.textSecondary)),
                        ),
                    ]),
                  ),
                ),
                if (_actionError != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_actionError!, style: const TextStyle(color: AppColors.negative, fontSize: 12.5))),
                const SizedBox(height: 14),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: AppColors.negative, minimumSize: const Size.fromHeight(52)),
                  onPressed: _saving ? null : _submit,
                  child: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : Text('Refund ${_returnTotal.toStringAsFixed(2)}'),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
