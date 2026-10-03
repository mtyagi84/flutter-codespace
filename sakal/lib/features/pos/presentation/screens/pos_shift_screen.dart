import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/app_logger.dart';
import '../widgets/pos_amount_field.dart';
import '../widgets/pos_keyboard.dart';
import '../widgets/pos_search_sheet.dart';
import '../widgets/pos_session_guard.dart';

/// Shift open / cash movements / close-and-cash-up — the operational loop a
/// cashier repeats every day. See docs/pos/04_shift_cash_management.md.
///
/// v1 scope note (deliberate, not an oversight): cash-up here collects one
/// DIRECT counted total per currency, not a full denomination breakdown —
/// `ric_companies.pos_require_denomination_count` and
/// `rid_pos_shift_denomination_counts` both already support the full grid
/// (a denomination_value=1 row is how a direct total is represented in that
/// same table, so adding the real grid later is additive, not a rework).
/// The expected-cash figure shown here is opening float + this shift's own
/// cash movements ONLY — it does not yet include cash sales, because the
/// Sales screen (rid_pos_tender_lines) hasn't been built yet; see this
/// screen's own `fn_close_pos_shift` counterpart in
/// backend/migrations/206_pos_shift_cash_management.sql for the same note.
class PosShiftScreen extends ConsumerStatefulWidget {
  const PosShiftScreen({super.key});

  @override
  ConsumerState<PosShiftScreen> createState() => _PosShiftScreenState();
}

class _PosShiftScreenState extends ConsumerState<PosShiftScreen> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _shift; // null = no open shift on this terminal
  List<Map<String, dynamic>> _currencies = [];
  List<Map<String, dynamic>> _accounts = [];
  List<Map<String, dynamic>> _openingFloat = [];
  List<Map<String, dynamic>> _movements = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    if (session.posTerminalId == null) {
      setState(() { _loading = false; _error = 'This isn\'t a POS till session. Sign out and sign back in from the POS Login screen.'; });
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        DioClient.instance.get('/rim_currencies', queryParameters: {
          'company_id': 'eq.${session.companyId}', 'is_active': 'eq.true', 'select': 'currency_id,currency_name',
        }),
        DioClient.instance.get('/rim_accounts', queryParameters: {
          'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
          'posting_allowed': 'eq.true', 'is_deleted': 'eq.false',
          'select': 'id,account_code,account_name,account_nature', 'order': 'account_code.asc',
        }),
        DioClient.instance.get('/rih_pos_shifts', queryParameters: {
          'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
          'terminal_id': 'eq.${session.posTerminalId}', 'status': 'eq.OPEN', 'is_deleted': 'eq.false',
          'select': 'id,shift_no,opened_at,cashier_id', 'limit': '1',
        }),
      ]);
      if (!mounted) return;
      _currencies = List<Map<String, dynamic>>.from(results[0].data as List);
      _accounts = List<Map<String, dynamic>>.from(results[1].data as List);
      final shifts = List<Map<String, dynamic>>.from(results[2].data as List);
      _shift = shifts.isEmpty ? null : shifts.first;

      if (_shift != null) {
        final subResults = await Future.wait([
          DioClient.instance.get('/rih_pos_shift_opening_float', queryParameters: {
            'shift_id': 'eq.${_shift!['id']}', 'select': 'currency_id,opening_amount',
          }),
          DioClient.instance.get('/rih_pos_payouts', queryParameters: {
            'shift_id': 'eq.${_shift!['id']}', 'is_deleted': 'eq.false',
            'select': 'id,movement_type,direction,amount,currency_id,reference_no,created_at', 'order': 'created_at.desc',
          }),
        ]);
        _openingFloat = List<Map<String, dynamic>>.from(subResults[0].data as List);
        _movements = List<Map<String, dynamic>>.from(subResults[1].data as List);
      } else {
        _openingFloat = [];
        _movements = [];
      }
      setState(() => _loading = false);
    } catch (e, st) {
      AppLogger.error('PosShiftLoad', e, st);
      if (mounted) setState(() { _loading = false; _error = ErrorPresenter.format(e, action: 'load shift status'); });
    }
  }

  void _showMsg(String msg, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  List<Map<String, dynamic>> get _nonCashAccounts =>
      _accounts.where((a) => a['account_nature'] != 'Cash' && a['account_nature'] != 'Bank').toList();
  List<Map<String, dynamic>> get _cashAccounts =>
      _accounts.where((a) => a['account_nature'] == 'Cash' || a['account_nature'] == 'Bank').toList();

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary, foregroundColor: Colors.white,
        title: Text('Shift & Cash — ${session?.posTerminalName ?? ''}'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.go(RouteNames.posSale)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? buildPosSessionGuardError(context, _error!, _load)
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 620),
                      child: _shift == null ? _buildOpenShift() : _buildOpenShiftActive(),
                    ),
                  ),
                ),
    );
  }

  Widget _buildOpenShift() {
    return _OpenShiftCard(currencies: _currencies, onOpened: _load, showMsg: _showMsg);
  }

  Widget _buildOpenShiftActive() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.check_circle, color: AppColors.positive, size: 20),
              const SizedBox(width: 8),
              Text(_shift!['shift_no'] as String, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            ]),
            const SizedBox(height: 6),
            Text('Opened ${_shift!['opened_at']}', style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5)),
          ]),
        ),
      ),
      const SizedBox(height: 14),
      _MovementTile(
        icon: Icons.south_west, color: AppColors.positive,
        title: 'Cash In', subtitle: 'Add cash to the drawer (e.g. a float top-up).',
        onTap: () => _openMovementDialog('CASH_IN'),
      ),
      const SizedBox(height: 10),
      _MovementTile(
        icon: Icons.receipt_long, color: AppColors.secondary,
        title: 'Pay Out', subtitle: 'Cash paid out for a reason — petty expense, courier, supplies.',
        onTap: () => _openMovementDialog('PAYOUT'),
      ),
      const SizedBox(height: 10),
      _MovementTile(
        icon: Icons.account_balance, color: AppColors.primary,
        title: 'Cash Drop', subtitle: 'Move excess cash to the safe for safekeeping — not an expense.',
        onTap: () => _openMovementDialog('CASH_DROP'),
      ),
      const SizedBox(height: 18),
      const Text('Today\'s Movements', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.textSecondary)),
      const SizedBox(height: 8),
      if (_movements.isEmpty)
        const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('No cash movements yet.', style: TextStyle(color: AppColors.textSecondary)))
      else
        ..._movements.map((m) => Card(
              child: ListTile(
                dense: true,
                leading: Icon(m['direction'] == 'IN' ? Icons.add_circle_outline : Icons.remove_circle_outline,
                    color: m['direction'] == 'IN' ? AppColors.positive : AppColors.negative),
                title: Text('${m['movement_type']} — ${m['amount']} ${m['currency_id']}'),
                subtitle: Text(m['reference_no'] as String? ?? ''),
              ),
            )),
      const SizedBox(height: 20),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(foregroundColor: AppColors.negative, side: const BorderSide(color: AppColors.negative)),
        onPressed: _openCloseShiftFlow,
        icon: const Icon(Icons.lock_outline),
        label: const Text('Close Shift & Cash Up'),
      ),
    ]);
  }

  Future<void> _openMovementDialog(String movementType) async {
    final session = ref.read(sessionProvider)!;
    // Every movement type needs BOTH a cash account (the drawer side) and
    // an "other side" account — a real bug found live: PAYOUT was passed
    // only non-cash accounts, so its own "Cash Account (drawer)" dropdown
    // had nothing to select at all, making every Payout un-submittable
    // ("Amount, currency, cash account... are all required" could never be
    // satisfied). The dialog's own build() already splits this combined
    // list back into cash vs. other by nature — this was the one call site
    // wrongly pre-filtering before that split ran.
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => _CashMovementDialog(
        movementType: movementType,
        currencies: _currencies,
        accounts: [..._cashAccounts, ..._nonCashAccounts],
        shiftId: _shift!['id'] as String,
        session: session,
      ),
    );
    if (result == true) {
      _showMsg('Recorded.', color: AppColors.positive);
      _load();
    }
  }

  Future<void> _openCloseShiftFlow() async {
    final session = ref.read(sessionProvider)!;
    // Currencies this shift actually touched — opening float ∪ movements.
    final touchedCurrencies = <String>{
      ..._openingFloat.map((f) => f['currency_id'] as String),
      ..._movements.map((m) => m['currency_id'] as String),
    };
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => _CloseShiftDialog(
        shiftId: _shift!['id'] as String,
        currencies: touchedCurrencies.isEmpty ? _currencies.map((c) => c['currency_id'] as String).toSet() : touchedCurrencies,
        openingFloat: _openingFloat,
        movements: _movements,
        session: session,
      ),
    );
    if (result == true) {
      _showMsg('Shift closed.', color: AppColors.positive);
      _load();
    }
  }
}

/// A full-width, large touch target (min 64dp tall) — replaces the old
/// 4-button grid whose "Cash Out" and "Payout" entries were functionally
/// duplicated (both just direction=OUT, confirmed confusing live) and whose
/// 1.1-aspect-ratio tiles were too small for a shop-floor finger tap.
class _MovementTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _MovementTile({required this.icon, required this.color, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
              alignment: Alignment.center,
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
                Text(subtitle, style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary)),
              ]),
            ),
            const Icon(Icons.chevron_right, color: AppColors.textSecondary),
          ]),
        ),
      ),
    );
  }
}

class _OpenShiftCard extends StatefulWidget {
  final List<Map<String, dynamic>> currencies;
  final VoidCallback onOpened;
  final void Function(String, {Color? color}) showMsg;
  const _OpenShiftCard({required this.currencies, required this.onOpened, required this.showMsg});

  @override
  State<_OpenShiftCard> createState() => _OpenShiftCardState();
}

class _OpenShiftCardState extends State<_OpenShiftCard> {
  final Map<String, double> _floatValues = {};
  String _notes = '';
  bool _saving = false;

  double _valueFor(String currency) => _floatValues[currency] ?? 0;

  Future<void> _open(WidgetRef ref) async {
    final session = ref.read(sessionProvider)!;
    setState(() => _saving = true);
    try {
      final floats = widget.currencies
          .map((c) => {'currency_id': c['currency_id'], 'amount': _valueFor(c['currency_id'] as String)})
          .where((f) => (f['amount'] as num) > 0)
          .toList();
      await DioClient.instance.post('/rpc/fn_open_pos_shift', data: {
        'p_client_id': session.clientId,
        'p_company_id': session.companyId,
        'p_terminal_id': session.posTerminalId,
        'p_cashier_id': session.userId,
        'p_opening_notes': _notes.trim(),
        'p_opening_floats': floats,
      });
      widget.onOpened();
      // A cashier who just opened a shift wants to start selling, not stare
      // at this screen's own summary view — same "land straight in New
      // Sale" convention as PIN login already uses.
      if (mounted) context.go(RouteNames.posSale);
    } catch (e, st) {
      AppLogger.error('PosOpenShift', e, st);
      widget.showMsg(ErrorPresenter.format(e, action: 'open this shift'), color: AppColors.negative);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer(builder: (context, ref, _) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Open Shift', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            const SizedBox(height: 4),
            const Text('Enter the opening float for each currency in the drawer.', style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5)),
            const SizedBox(height: 16),
            ...widget.currencies.map((c) {
              final currency = c['currency_id'] as String;
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: PosAmountField(
                  label: 'Opening Float ($currency)',
                  value: _valueFor(currency),
                  suffixText: currency,
                  onChanged: (v) => setState(() => _floatValues[currency] = v),
                ),
              );
            }),
            PosKeyboardField(label: 'Notes (optional)', value: _notes, onChanged: (v) => setState(() => _notes = v)),
            const SizedBox(height: 16),
            SizedBox(
              height: 52,
              child: FilledButton(
                onPressed: _saving ? null : () => _open(ref),
                child: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Open Shift'),
              ),
            ),
          ]),
        ),
      );
    });
  }
}

class _CashMovementDialog extends StatefulWidget {
  final String movementType;
  final List<Map<String, dynamic>> currencies;
  final List<Map<String, dynamic>> accounts;
  final String shiftId;
  final UserSession session;
  const _CashMovementDialog({required this.movementType, required this.currencies, required this.accounts, required this.shiftId, required this.session});

  @override
  State<_CashMovementDialog> createState() => _CashMovementDialogState();
}

class _CashMovementDialogState extends State<_CashMovementDialog> {
  double _amount = 0;
  String _note = '';
  String? _currencyId;
  String? _accountId;
  String? _accountDisplay;
  String? _cashAccountId;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _currencyId = widget.currencies.isNotEmpty ? widget.currencies.first['currency_id'] as String : null;
  }

  Future<void> _submit() async {
    final amount = _amount;
    if (amount <= 0 || _currencyId == null || _accountId == null || _cashAccountId == null) {
      setState(() => _error = 'Amount, currency, cash account, and the other account are all required.');
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      await DioClient.instance.post('/rpc/fn_save_pos_cash_movement', data: {
        'p_client_id': widget.session.clientId,
        'p_company_id': widget.session.companyId,
        'p_shift_id': widget.shiftId,
        'p_movement_type': widget.movementType,
        'p_amount': amount,
        'p_currency_id': _currencyId,
        'p_cash_account_id': _cashAccountId,
        'p_counter_account_id': _accountId,
        'p_reason_id': null,
        'p_reference_no': _note.trim(),
        'p_created_by': widget.session.userId,
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e, st) {
      AppLogger.error('PosCashMovement', e, st);
      if (mounted) setState(() => _error = ErrorPresenter.format(e, action: 'record this movement'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickOtherAccount(List<Map<String, dynamic>> otherAccounts) async {
    await PosSearchSheet.show<Map<String, dynamic>>(
      context,
      title: widget.movementType == 'PAYOUT' ? 'Select Expense Account' : 'Select Other Account',
      hintText: 'Search account name or code…',
      onSearch: (q) async {
        if (q.isEmpty) return otherAccounts;
        final lower = q.toLowerCase();
        return otherAccounts.where((a) =>
            (a['account_code'] as String).toLowerCase().contains(lower) ||
            (a['account_name'] as String).toLowerCase().contains(lower)).toList();
      },
      itemBuilder: (context, a) => ListTile(title: Text('${a['account_code']} — ${a['account_name']}')),
      onSelected: (a) => setState(() {
        _accountId = a['id'] as String;
        _accountDisplay = '${a['account_code']} — ${a['account_name']}';
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cashAccounts = widget.accounts.where((a) => a['account_nature'] == 'Cash' || a['account_nature'] == 'Bank').toList();
    final otherAccounts = widget.accounts.where((a) => a['account_nature'] != 'Cash' && a['account_nature'] != 'Bank').toList();
    return AlertDialog(
      title: Text(_titleFor(widget.movementType)),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_explanationFor(widget.movementType), style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
          const SizedBox(height: 14),
          PosAmountField(label: 'Amount', value: _amount, suffixText: _currencyId, onChanged: (v) => setState(() => _amount = v)),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _currencyId, isExpanded: true, isDense: true, itemHeight: null,
            decoration: const InputDecoration(labelText: 'Currency', border: OutlineInputBorder()),
            items: widget.currencies.map((c) => DropdownMenuItem(value: c['currency_id'] as String, child: Text(c['currency_id'] as String))).toList(),
            onChanged: (v) => setState(() => _currencyId = v),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _cashAccountId, isExpanded: true, isDense: true, itemHeight: null,
            decoration: const InputDecoration(labelText: 'Cash Account (drawer)', border: OutlineInputBorder()),
            items: cashAccounts.map((a) => DropdownMenuItem(value: a['id'] as String, child: Text('${a['account_code']} — ${a['account_name']}', overflow: TextOverflow.ellipsis))).toList(),
            onChanged: (v) => setState(() => _cashAccountId = v),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 3, left: 2),
            child: Text('The physical till/cash box this terminal uses — where the cash itself physically moves.', style: TextStyle(fontSize: 10.5, color: AppColors.textSecondary)),
          ),
          const SizedBox(height: 10),
          // A plain dropdown doesn't scale to a full Chart of Accounts —
          // this list can be hundreds of rows long, so it's a live-searched
          // picker instead, same pattern as Customer search elsewhere.
          Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _pickOtherAccount(otherAccounts),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.border)),
                child: Row(children: [
                  const Icon(Icons.search, size: 18, color: AppColors.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _accountDisplay ?? (widget.movementType == 'PAYOUT' ? 'Select Expense Account' : 'Select Other Account'),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: _accountDisplay == null ? AppColors.textSecondary : AppColors.textPrimary),
                    ),
                  ),
                ]),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 3, left: 2),
            child: Text(
              widget.movementType == 'PAYOUT' ? 'What the cash was spent on (e.g. courier, supplies).' : 'The safe, bank, or other account this cash is moving to/from.',
              style: const TextStyle(fontSize: 10.5, color: AppColors.textSecondary),
            ),
          ),
          const SizedBox(height: 10),
          PosKeyboardField(label: 'Note', value: _note, onChanged: (v) => setState(() => _note = v)),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: AppColors.negative, fontSize: 12))),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(onPressed: _saving ? null : _submit, child: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save')),
      ],
    );
  }

  String _titleFor(String t) => switch (t) {
        'CASH_IN' => 'Cash In',
        'CASH_OUT' => 'Cash Out',
        'PAYOUT' => 'Payout',
        'CASH_DROP' => 'Cash Drop',
        _ => t,
      };

  String _explanationFor(String t) => switch (t) {
        'CASH_IN' => 'Add cash to the drawer — e.g. a float top-up from the office.',
        'PAYOUT' => 'Record cash paid out of the drawer for a reason — a petty expense, courier, or supplies.',
        'CASH_DROP' => 'Move excess cash OUT of the drawer into the safe for safekeeping — this is not an expense, the money is still the business\'s, just no longer sitting in the till.',
        _ => '',
      };
}

class _CloseShiftDialog extends StatefulWidget {
  final String shiftId;
  final Set<String> currencies;
  final List<Map<String, dynamic>> openingFloat;
  final List<Map<String, dynamic>> movements;
  final UserSession session;
  const _CloseShiftDialog({required this.shiftId, required this.currencies, required this.openingFloat, required this.movements, required this.session});

  @override
  State<_CloseShiftDialog> createState() => _CloseShiftDialogState();
}

class _CloseShiftDialogState extends State<_CloseShiftDialog> {
  final Map<String, double> _countedValues = {};
  String _notes = '';
  String _reason = '';
  bool _saving = false;
  String? _error;

  double _valueFor(String currency) => _countedValues[currency] ?? 0;

  double _expectedFor(String currency) {
    final opening = widget.openingFloat.where((f) => f['currency_id'] == currency).fold<double>(0, (s, f) => s + (f['opening_amount'] as num).toDouble());
    final inAmt = widget.movements.where((m) => m['currency_id'] == currency && m['direction'] == 'IN').fold<double>(0, (s, m) => s + (m['amount'] as num).toDouble());
    final outAmt = widget.movements.where((m) => m['currency_id'] == currency && m['direction'] == 'OUT').fold<double>(0, (s, m) => s + (m['amount'] as num).toDouble());
    return opening + inAmt - outAmt;
  }

  Future<void> _submit() async {
    setState(() { _saving = true; _error = null; });
    try {
      // v1: one row per currency representing a DIRECT counted total (no
      // denomination breakdown yet — see this screen's own header comment).
      for (final currency in widget.currencies) {
        final counted = _valueFor(currency);
        // Upsert, not a plain INSERT: if a prior Close Shift attempt failed
        // AFTER this insert already succeeded (e.g. fn_close_pos_shift
        // itself then rejected a missing variance reason), retrying used to
        // hit "duplicate key value violates unique constraint
        // uq_pos_shift_denom_count" — confirmed live. This must be safely
        // re-runnable.
        await DioClient.instance.post(
          '/rid_pos_shift_denomination_counts',
          data: {
            'client_id': widget.session.clientId,
            'company_id': widget.session.companyId,
            'shift_id': widget.shiftId,
            'count_stage': 'CLOSING',
            'currency_id': currency,
            'denomination_value': 1,
            'count': counted,
          },
          queryParameters: {'on_conflict': 'shift_id,count_stage,currency_id,denomination_value'},
          options: Options(headers: {'Prefer': 'resolution=merge-duplicates'}),
        );
      }
      await DioClient.instance.post('/rpc/fn_close_pos_shift', data: {
        'p_client_id': widget.session.clientId,
        'p_company_id': widget.session.companyId,
        'p_shift_id': widget.shiftId,
        'p_closing_notes': _notes.trim(),
        'p_variance_reason': _reason.trim().isEmpty ? null : _reason.trim(),
        'p_approved_by': null,
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e, st) {
      AppLogger.error('PosCloseShift', e, st);
      if (mounted) setState(() => _error = ErrorPresenter.format(e, action: 'close this shift'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Close Shift & Cash Up'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ...widget.currencies.map((currency) {
              final expected = _expectedFor(currency);
              final counted = _valueFor(currency);
              final variance = counted - expected;
              return Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(currency, style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text('Expected: ${expected.toStringAsFixed(2)}', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                  const SizedBox(height: 6),
                  PosAmountField(
                    label: 'Counted Amount',
                    value: counted,
                    suffixText: currency,
                    onChanged: (v) => setState(() => _countedValues[currency] = v),
                  ),
                  if (counted != 0 || expected != 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('Variance: ${variance.toStringAsFixed(2)}',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: variance.abs() > 0.01 ? AppColors.negative : AppColors.positive)),
                    ),
                ]),
              );
            }),
            PosKeyboardField(label: 'Variance Reason (if any)', value: _reason, onChanged: (v) => setState(() => _reason = v)),
            const SizedBox(height: 10),
            PosKeyboardField(label: 'Closing Notes (optional)', value: _notes, onChanged: (v) => setState(() => _notes = v)),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: const TextStyle(color: AppColors.negative, fontSize: 12))),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.negative),
          onPressed: _saving ? null : _submit,
          child: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Close Shift'),
        ),
      ],
    );
  }
}
