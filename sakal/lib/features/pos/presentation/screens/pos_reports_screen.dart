import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/app_logger.dart';

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
  double _openingFloat = 0;
  double _cashIn = 0;
  double _cashOut = 0;
  double _payout = 0;
  double _cashDrop = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadShifts());
  }

  Future<void> _loadShifts() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
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

    final floatRes = await DioClient.instance.get('/rih_pos_shift_opening_float', queryParameters: {'shift_id': 'eq.$shiftId', 'select': 'opening_amount'});
    _openingFloat = (floatRes.data as List).fold(0, (s, r) => s + ((r as Map<String, dynamic>)['opening_amount'] as num).toDouble());

    final payoutRes = await DioClient.instance.get('/rih_pos_payouts', queryParameters: {'shift_id': 'eq.$shiftId', 'is_deleted': 'eq.false', 'select': 'movement_type,amount'});
    final payouts = List<Map<String, dynamic>>.from(payoutRes.data as List);
    _cashIn = payouts.where((p) => p['movement_type'] == 'CASH_IN').fold(0, (s, p) => s + (p['amount'] as num).toDouble());
    _cashOut = payouts.where((p) => p['movement_type'] == 'CASH_OUT').fold(0, (s, p) => s + (p['amount'] as num).toDouble());
    _payout = payouts.where((p) => p['movement_type'] == 'PAYOUT').fold(0, (s, p) => s + (p['amount'] as num).toDouble());
    _cashDrop = payouts.where((p) => p['movement_type'] == 'CASH_DROP').fold(0, (s, p) => s + (p['amount'] as num).toDouble());
  }

  double get _expectedCash => _openingFloat + _cashSales + _cashIn - _cashOut - _payout - _cashDrop;

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
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_error!, style: const TextStyle(color: AppColors.negative)),
                  TextButton(onPressed: _loadShifts, child: const Text('Retry')),
                ]))
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
                            _sectionCard('Cash Movements', [
                              _row('Opening Float', _openingFloat.toStringAsFixed(2)),
                              _row('Cash In', _cashIn.toStringAsFixed(2)),
                              _row('Cash Out', (-_cashOut).toStringAsFixed(2)),
                              _row('Payouts', (-_payout).toStringAsFixed(2)),
                              _row('Cash Drops', (-_cashDrop).toStringAsFixed(2)),
                              _row('Expected Cash', _expectedCash.toStringAsFixed(2), bold: true),
                            ]),
                            const SizedBox(height: 12),
                            const Text(
                              'Tender-method and multi-currency breakdowns will appear here once split-tender payments ship (see docs/pos/03_payments_multicurrency.md).',
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
