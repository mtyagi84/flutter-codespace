import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../sales/presentation/providers/sales_return_providers.dart';

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
  final TextEditingController returnQtyCtrl = TextEditingController(text: '0');

  double get remaining => soldQty - alreadyReturned;

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
  });

  void dispose() => returnQtyCtrl.dispose();
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

  bool get _showRefund => _invoice != null && _invoice!['sale_type'] == 'CASH' && _invoice!['cash_collection_mode'] == 'IMMEDIATE';

  double get _taxableTotal => _lines.fold(0, (s, l) {
        final qty = double.tryParse(l.returnQtyCtrl.text) ?? 0;
        return s + qty * l.rate;
      });
  double get _taxTotal => 0; // simplified v1 — see header note on tax below
  double get _returnTotal => _taxableTotal + _taxTotal;

  @override
  void dispose() {
    _searchCtrl.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  Future<void> _findInvoice(String value) async {
    final invoiceNo = value.trim();
    if (invoiceNo.isEmpty) return;
    final session = ref.read(sessionProvider)!;
    final ds = ref.read(salesReturnRepositoryProvider);
    setState(() { _searching = true; _error = null; _invoice = null; _lines.clear(); });
    try {
      final matches = await ds.getApprovedInvoices(clientId: session.clientId, companyId: session.companyId, search: invoiceNo);
      final match = matches.where((i) => i['invoice_no'] == invoiceNo).toList();
      if (match.isEmpty) {
        setState(() { _searching = false; _error = 'No approved invoice found for "$invoiceNo".'; });
        return;
      }
      _invoice = match.first;
      final invDate = _invoice!['invoice_date'] as String;

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
        ));
      }
      setState(() => _searching = false);
    } catch (e, st) {
      AppLogger.error('PosReturnFind', e, st);
      if (mounted) setState(() { _searching = false; _error = ErrorPresenter.format(e, action: 'find this invoice'); });
    }
  }

  Future<void> _submit() async {
    final returnLines = _lines.where((l) => (double.tryParse(l.returnQtyCtrl.text) ?? 0) > 0).toList();
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
        final qty = double.tryParse(e.value.returnQtyCtrl.text) ?? 0;
        final gross = qty * e.value.rate;
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
          'gross_amount': gross,
          'tax_amount': 0,
          'final_amount': gross,
        };
      }).toList();

      final ds = ref.read(salesReturnRepositoryProvider);
      final returnNo = await ds.save(header: header, lines: lines, batches: const [], serials: const [], charges: const [], userId: session.userId);
      await ds.approve(clientId: session.clientId, companyId: session.companyId, returnNo: returnNo, returnDate: _fmtDate(DateTime.now()), approvedBy: session.userId);

      if (mounted) {
        _showMsg('$returnNo completed.', color: AppColors.positive);
        context.go(RouteNames.posSale);
      }
    } catch (e, st) {
      AppLogger.error('PosReturnSubmit', e, st);
      if (mounted) setState(() => _actionError = ErrorPresenter.format(e, action: 'complete this return'));
    } finally {
      if (mounted) setState(() => _saving = false);
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
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl, autofocus: true,
                    decoration: const InputDecoration(hintText: 'Invoice number…', border: OutlineInputBorder(), isDense: true),
                    onSubmitted: _findInvoice,
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(onPressed: _searching ? null : () => _findInvoice(_searchCtrl.text), child: _searching ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Find')),
              ]),
              if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: const TextStyle(color: AppColors.negative))),
              if (_invoice != null) ...[
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
                            width: 90,
                            child: TextField(
                              controller: l.returnQtyCtrl,
                              enabled: !l.isTracked && l.remaining > 0,
                              textAlign: TextAlign.center,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              decoration: const InputDecoration(isDense: true, labelText: 'Return Qty'),
                              onChanged: (_) => setState(() {}),
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
