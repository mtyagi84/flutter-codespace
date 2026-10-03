import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/app_logger.dart';
import '../widgets/pos_session_guard.dart';

/// Z-report / shift summary — v1 scope. Reads `rih_sales_invoices`/
/// `rih_pos_payouts`/`rih_pos_shift_opening_float` directly, NOT any GL
/// table, per docs/pos/08_reporting_audit.md: "no report built in this
/// design depends on GL timing." Does not yet break totals down by tender
/// method (rid_pos_tender_lines doesn't exist yet, see migration 207's own
/// header note) — that's an additive follow-up once split-tender ships.
class PosReportsScreen extends ConsumerStatefulWidget {
  const PosReportsScreen({super.key});

  @override
  ConsumerState<PosReportsScreen> createState() => _PosReportsScreenState();
}

class _PosReportsScreenState extends ConsumerState<PosReportsScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _shifts = [];
  String? _selectedShiftId;

  double _salesTotal = 0;
  int _salesCount = 0;
  double _cashSales = 0;
  double _creditSales = 0;
  String _localCcy = '';

  // Every cash figure is kept PER CURRENCY — 1500 CDF and 10 USD can never
  // correctly be summed into one number, which is exactly the bug a live
  // user report caught (opening float shown as "15010.00" instead of two
  // separate lines). Cash Out and Payout are merged here (both are simply
  // "cash leaving the drawer for a reason") — Cash Drop stays separate since
  // it's a safekeeping transfer, not an expense.
  final Map<String, double> _openingFloatByCcy = {};
  final Map<String, double> _cashInByCcy = {};
  final Map<String, double> _cashOutByCcy = {};
  final Map<String, double> _cashDropByCcy = {};

  Set<String> get _touchedCurrencies => {
        ..._openingFloatByCcy.keys,
        ..._cashInByCcy.keys,
        ..._cashOutByCcy.keys,
        ..._cashDropByCcy.keys,
        if (_localCcy.isNotEmpty) _localCcy,
      };

  double _expectedCashFor(String currency) {
    final opening = _openingFloatByCcy[currency] ?? 0;
    final cashIn = _cashInByCcy[currency] ?? 0;
    final cashOut = _cashOutByCcy[currency] ?? 0;
    final cashDrop = _cashDropByCcy[currency] ?? 0;
    // Cash sales are always collected in the company's own local currency —
    // the only currency a physical drawer ever actually holds (same "cash
    // is always local" rule New Sale enforces when forcing the invoice
    // currency for a CASH sale).
    final cashSales = currency == _localCcy ? _cashSales : 0;
    return opening + cashSales + cashIn - cashOut - cashDrop;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadShifts());
  }

  Future<void> _loadShifts() async {
    final session = ref.read(sessionProvider)!;
    if (session.posTerminalId == null) {
      setState(() { _loading = false; _error = 'This isn\'t a POS till session. Sign out and sign back in from the POS Login screen.'; });
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final companyRes = await DioClient.instance.get('/ric_companies', queryParameters: {
        'id': 'eq.${session.companyId}', 'select': 'local_currency',
      });
      _localCcy = ((companyRes.data as List).first as Map<String, dynamic>)['local_currency'] as String? ?? '';

      final res = await DioClient.instance.get('/rih_pos_shifts', queryParameters: {
        'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
        'terminal_id': 'eq.${session.posTerminalId}', 'is_deleted': 'eq.false',
        'select': 'id,shift_no,status,opened_at', 'order': 'opened_at.desc', 'limit': '30',
      });
      _shifts = List<Map<String, dynamic>>.from(res.data as List);
      if (_shifts.isNotEmpty) {
        _selectedShiftId = _shifts.first['id'] as String;
        await _loadShiftTotals(session, _selectedShiftId!);
      }
      if (mounted) setState(() => _loading = false);
    } catch (e, st) {
      AppLogger.error('PosReportsLoad', e, st);
      if (mounted) setState(() { _loading = false; _error = ErrorPresenter.format(e, action: 'load shifts'); });
    }
  }

  Future<void> _loadShiftTotals(UserSession session, String shiftId) async {
    final invRes = await DioClient.instance.get('/rih_sales_invoices', queryParameters: {
      'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
      'pos_shift_id': 'eq.$shiftId', 'status': 'eq.APPROVED', 'is_deleted': 'eq.false',
      'select': 'sale_type,grand_total',
    });
    final invoices = List<Map<String, dynamic>>.from(invRes.data as List);
    _salesCount = invoices.length;
    _salesTotal = invoices.fold(0, (s, i) => s + (i['grand_total'] as num).toDouble());
    _cashSales = invoices.where((i) => i['sale_type'] == 'CASH').fold(0, (s, i) => s + (i['grand_total'] as num).toDouble());
    _creditSales = _salesTotal - _cashSales;

    _openingFloatByCcy.clear();
    _cashInByCcy.clear();
    _cashOutByCcy.clear();
    _cashDropByCcy.clear();

    final floatRes = await DioClient.instance.get('/rih_pos_shift_opening_float', queryParameters: {'shift_id': 'eq.$shiftId', 'select': 'currency_id,opening_amount'});
    for (final r in (floatRes.data as List).cast<Map<String, dynamic>>()) {
      final ccy = r['currency_id'] as String;
      _openingFloatByCcy[ccy] = (_openingFloatByCcy[ccy] ?? 0) + (r['opening_amount'] as num).toDouble();
    }

    final payoutRes = await DioClient.instance.get('/rih_pos_payouts', queryParameters: {'shift_id': 'eq.$shiftId', 'is_deleted': 'eq.false', 'select': 'movement_type,amount,currency_id'});
    for (final p in (payoutRes.data as List).cast<Map<String, dynamic>>()) {
      final ccy = p['currency_id'] as String;
      final amount = (p['amount'] as num).toDouble();
      switch (p['movement_type']) {
        case 'CASH_IN':
          _cashInByCcy[ccy] = (_cashInByCcy[ccy] ?? 0) + amount;
        case 'CASH_OUT':
        case 'PAYOUT':
          _cashOutByCcy[ccy] = (_cashOutByCcy[ccy] ?? 0) + amount;
        case 'CASH_DROP':
          _cashDropByCcy[ccy] = (_cashDropByCcy[ccy] ?? 0) + amount;
      }
    }
  }

  Future<void> _onShiftChanged(String? id) async {
    if (id == null) return;
    setState(() => _selectedShiftId = id);
    final session = ref.read(sessionProvider)!;
    await _loadShiftTotals(session, id);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary, foregroundColor: Colors.white,
        title: const Text('POS Reports'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.go(RouteNames.posSale)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? buildPosSessionGuardError(context, _error!, _loadShifts)
              : _shifts.isEmpty
                  ? const Center(child: Text('No shifts yet on this till.', style: TextStyle(color: AppColors.textSecondary)))
                  : Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(16),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            DropdownButtonFormField<String>(
                              initialValue: _selectedShiftId,
                              isExpanded: true, isDense: true, itemHeight: null,
                              decoration: const InputDecoration(labelText: 'Shift', border: OutlineInputBorder()),
                              items: _shifts.map((s) => DropdownMenuItem(value: s['id'] as String, child: Text('${s['shift_no']} (${s['status']})'))).toList(),
                              onChanged: _onShiftChanged,
                            ),
                            const SizedBox(height: 16),
                            _sectionCard('Sales', [
                              _row('Transactions', _salesCount.toString()),
                              _row('Cash Sales', _cashSales.toStringAsFixed(2)),
                              _row('Credit Sales', _creditSales.toStringAsFixed(2)),
                              _row('Total Sales', _salesTotal.toStringAsFixed(2), bold: true),
                            ]),
                            const SizedBox(height: 12),
                            // One card PER CURRENCY — never a single blended
                            // number (the real bug a live user report caught:
                            // 1500 CDF + 10 USD can never correctly become
                            // one figure).
                            ..._touchedCurrencies.map((ccy) => Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: _sectionCard('Cash Movements ($ccy)', [
                                    _row('Opening Float', (_openingFloatByCcy[ccy] ?? 0).toStringAsFixed(2)),
                                    if (ccy == _localCcy) _row('Cash Sales', _cashSales.toStringAsFixed(2)),
                                    _row('Cash In', (_cashInByCcy[ccy] ?? 0).toStringAsFixed(2)),
                                    _row('Pay Outs', (-(_cashOutByCcy[ccy] ?? 0)).toStringAsFixed(2)),
                                    _row('Cash Drops', (-(_cashDropByCcy[ccy] ?? 0)).toStringAsFixed(2)),
                                    _row('Expected Cash', _expectedCashFor(ccy).toStringAsFixed(2), bold: true),
                                  ]),
                                )),
                            const Text(
                              'Tender-method breakdowns will appear here once split-tender payments ship (see docs/pos/03_payments_multicurrency.md).',
                              style: TextStyle(fontSize: 11.5, color: AppColors.textSecondary),
                            ),
                          ]),
                        ),
                      ),
                    ),
    );
  }

  Widget _sectionCard(String title, List<Widget> rows) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
            const SizedBox(height: 8),
            ...rows,
          ]),
        ),
      );

  Widget _row(String label, String value, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: TextStyle(fontSize: 13, fontWeight: bold ? FontWeight.w800 : FontWeight.w400, color: bold ? AppColors.textPrimary : AppColors.textSecondary)),
          Text(value, style: TextStyle(fontSize: 13, fontWeight: bold ? FontWeight.w800 : FontWeight.w600)),
        ]),
      );
}
