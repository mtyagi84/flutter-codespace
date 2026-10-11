import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../widgets/pos_amount_field.dart';

const _posTenderTypesForPayment = ['CASH', 'CARD', 'MOBILE_MONEY', 'VOUCHER', 'GIFT_CARD', 'STORE_CREDIT'];

String _tenderTypeLabelForPayment(String t) => switch (t) {
      'CASH' => 'Cash',
      'CARD' => 'Card',
      'MOBILE_MONEY' => 'Mobile Money',
      'VOUCHER' => 'Voucher',
      'GIFT_CARD' => 'Gift Card',
      'STORE_CREDIT' => 'Store Credit',
      _ => t,
    };

const _tenderIconsForPayment = {
  'CASH': Icons.payments_outlined,
  'CARD': Icons.credit_card_outlined,
  'MOBILE_MONEY': Icons.smartphone_outlined,
  'VOUCHER': Icons.card_giftcard_outlined,
  'GIFT_CARD': Icons.redeem_outlined,
  'STORE_CREDIT': Icons.account_balance_wallet_outlined,
};

class _PayLine {
  String tenderType;
  String currencyId;
  double amount;
  String? referenceNo;
  _PayLine({required this.tenderType, required this.currencyId, required this.amount, this.referenceNo});
}

/// Dedicated full PAGE (never a modal/bottom sheet) for collecting payment
/// on a cash POS sale — reached ONLY from New Sale's "Charge" button,
/// mirroring `PosCreditCheckoutScreen`'s own shape exactly (real user
/// instruction): a compact read-only totals summary up top, the real
/// editing area with room to breathe in the middle, and a single pinned
/// "Save & Print" button at the bottom. Returns the finished list of
/// payment lines via `Navigator.pop(context, lines)` — New Sale itself
/// performs the actual save/approve/print/reset, reusing its own existing
/// `_charge()` exactly like Credit Checkout already does.
///
/// Real UX bug fixed 2026-10-11, twice: the first fix made this a modal
/// bottom sheet (still confusing — no clear "where do I type the amount"),
/// the second fix put it back inline on the cramped New Sale side panel
/// (wrong — the user asked for a dedicated PAGE, not for everything
/// squeezed onto the main screen). This is the actual, correctly-scoped
/// fix: its own page, Payment Mode and the Amount box laid out SIDE BY
/// SIDE with real room, large tappable chips instead of a dropdown/popup
/// list (a touchscreen cannot comfortably drive either of those), and a
/// currency switch immediately shows how much to collect in the newly
/// chosen currency via `rateToLocal` (pre-fetched by the caller before
/// navigating here, so this screen never needs its own network calls).
class PosPaymentCheckoutScreen extends StatefulWidget {
  final double subtotal;
  final double discount;
  final double tax;
  final double total;
  final double dueAmount;
  final double? exchangeCreditAmount;
  final String localCurrency;
  final List<Map<String, dynamic>> currencies; // [{'currency_id': 'USD'}, ...]
  final Map<String, double> rateToLocal; // currencyId -> local units per 1 unit of that currency
  final List<Map<String, dynamic>> initialLines;

  const PosPaymentCheckoutScreen({
    super.key,
    required this.subtotal,
    required this.discount,
    required this.tax,
    required this.total,
    required this.dueAmount,
    this.exchangeCreditAmount,
    required this.localCurrency,
    required this.currencies,
    required this.rateToLocal,
    required this.initialLines,
  });

  @override
  State<PosPaymentCheckoutScreen> createState() => _PosPaymentCheckoutScreenState();
}

class _PosPaymentCheckoutScreenState extends State<PosPaymentCheckoutScreen> {
  late final List<_PayLine> _lines = widget.initialLines
      .map((m) => _PayLine(
            tenderType: m['tenderType'] as String,
            currencyId: m['currencyId'] as String,
            amount: m['amount'] as double,
            referenceNo: m['referenceNo'] as String?,
          ))
      .toList();

  double get _collectedLocal => _lines.fold(0.0, (s, l) => s + l.amount * (l.currencyId == widget.localCurrency ? 1 : (widget.rateToLocal[l.currencyId] ?? 1)));
  double get _diff => _collectedLocal - widget.dueAmount;

  // Real bug fixed 2026-10-11: a foreign-currency amount can only be typed
  // to 2 decimal places, but at a high local-currency rate (e.g. 1 EUR ~
  // 3,097 CDF) one cent of rounding is worth ~31 CDF — an exact match is
  // mathematically unreachable once a cashier types the rounded figure the
  // "Collect X <ccy> to cover Y <local>" hint itself shows. Half a cent of
  // the highest-rate currency in use bounds this unavoidable gap; a plain
  // local-currency-only cash sale keeps a tight ~0.005 tolerance, same as
  // the previous flat 0.01. Must match pos_new_sale_screen.dart's own
  // `_tenderRoundingTolerance` — _charge() re-validates with that same
  // formula after this screen hands back its result.
  double get _roundingTolerance {
    var maxRate = 1.0;
    for (final l in _lines) {
      if (l.currencyId == widget.localCurrency) continue;
      final r = widget.rateToLocal[l.currencyId] ?? 1;
      if (r > maxRate) maxRate = r;
    }
    return 0.005 * maxRate;
  }

  bool get _short => _diff < -_roundingTolerance;
  double get _displayDiff => _diff.abs() <= _roundingTolerance ? 0.0 : _diff;

  void _addLine() {
    final unused = widget.currencies.map((c) => c['currency_id'] as String).firstWhere(
          (c) => !_lines.any((l) => l.currencyId == c),
          orElse: () => widget.localCurrency,
        );
    setState(() => _lines.add(_PayLine(tenderType: 'CASH', currencyId: unused, amount: 0)));
  }

  void _save() {
    if (_short) return;
    Navigator.of(context).pop(_lines
        .map((l) => {'tenderType': l.tenderType, 'currencyId': l.currencyId, 'amount': l.amount, 'referenceNo': l.referenceNo})
        .toList());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary, foregroundColor: Colors.white,
        title: const Text('Payment'),
      ),
      body: Column(children: [
        Container(
          width: double.infinity,
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                child: Text(
                  'Subtotal ${widget.subtotal.toStringAsFixed(2)}  ·  Disc -${widget.discount.toStringAsFixed(2)}  ·  Tax ${widget.tax.toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text('${widget.total.toStringAsFixed(2)} ${widget.localCurrency}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            ]),
            if (widget.exchangeCreditAmount != null) ...[
              const SizedBox(height: 4),
              Text(
                'Exchange credit applied: ${widget.exchangeCreditAmount!.toStringAsFixed(2)} ${widget.localCurrency} — amount due ${widget.dueAmount.toStringAsFixed(2)} ${widget.localCurrency}',
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.secondary),
              ),
            ],
          ]),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final line in _lines) _buildLineCard(line),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(onPressed: _addLine, icon: const Icon(Icons.add), label: const Text('Add Payment Method')),
              ),
            ]),
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.border)), color: Colors.white),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('Collected', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
              Text('${_collectedLocal.toStringAsFixed(2)} ${widget.localCurrency}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            ]),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(_short ? 'Short by' : 'Change Due', style: TextStyle(fontSize: 13, color: _short ? AppColors.negative : AppColors.positive, fontWeight: FontWeight.w600)),
              Text('${_displayDiff.abs().toStringAsFixed(2)} ${widget.localCurrency}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _short ? AppColors.negative : AppColors.positive)),
            ]),
            const SizedBox(height: 10),
            SafeArea(
              top: false,
              minimum: const EdgeInsets.only(bottom: 12),
              child: SizedBox(
                height: 54,
                child: FilledButton.icon(
                  onPressed: _short ? null : _save,
                  style: FilledButton.styleFrom(backgroundColor: AppColors.secondary),
                  icon: const Icon(Icons.print_outlined),
                  label: Text(_short ? 'Short by ${_diff.abs().toStringAsFixed(2)} ${widget.localCurrency}' : 'Save & Print', style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _buildLineCard(_PayLine line) {
    // What's still needed, converted into THIS line's own currency — so
    // switching currency immediately shows how much to actually collect
    // in it, instead of leaving the cashier to do the maths themselves.
    final othersLocal = _lines.where((l) => l != line).fold(0.0, (s, l) => s + l.amount * (l.currencyId == widget.localCurrency ? 1 : (widget.rateToLocal[l.currencyId] ?? 1)));
    final remainingLocalExcl = widget.dueAmount - othersLocal;
    final rate = line.currencyId == widget.localCurrency ? 1.0 : (widget.rateToLocal[line.currencyId] ?? 1.0);
    final neededInCcy = rate == 0 ? 0.0 : remainingLocalExcl / rate;

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_lines.length > 1)
          Row(children: [
            Expanded(child: Text(_tenderTypeLabelForPayment(line.tenderType), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5))),
            IconButton(
              onPressed: () => setState(() => _lines.remove(line)),
              icon: const Icon(Icons.delete_outline, size: 20, color: AppColors.negative),
              tooltip: 'Remove this payment method',
            ),
          ]),
        LayoutBuilder(builder: (context, constraints) {
          final sideBySide = constraints.maxWidth >= 560;
          final modeSelector = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Payment Mode', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: _posTenderTypesForPayment.map((t) {
              final sel = line.tenderType == t;
              return InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => setState(() => line.tenderType = t),
                child: Container(
                  width: 92, height: 54,
                  decoration: BoxDecoration(
                    color: sel ? AppColors.secondary.withValues(alpha: 0.15) : AppColors.background,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: sel ? AppColors.secondary : AppColors.border, width: sel ? 1.5 : 1),
                  ),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(_tenderIconsForPayment[t], size: 18, color: sel ? AppColors.secondary : AppColors.textSecondary),
                    const SizedBox(height: 3),
                    Text(_tenderTypeLabelForPayment(t), textAlign: TextAlign.center, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: sel ? AppColors.secondary : AppColors.textPrimary)),
                  ]),
                ),
              );
            }).toList()),
          ]);

          final amountSection = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Text('Amount', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
              const Spacer(),
              if (widget.currencies.length > 1)
                Wrap(spacing: 6, children: widget.currencies.map((c) {
                  final ccyId = c['currency_id'] as String;
                  final sel = line.currencyId == ccyId;
                  return InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => setState(() => line.currencyId = ccyId),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: sel ? AppColors.primary.withValues(alpha: 0.12) : AppColors.background,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: sel ? AppColors.primary : AppColors.border),
                      ),
                      child: Text(ccyId, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: sel ? AppColors.primary : AppColors.textPrimary)),
                    ),
                  );
                }).toList()),
            ]),
            const SizedBox(height: 6),
            PosAmountField(label: 'Amount Collected', value: line.amount, suffixText: line.currencyId, onChanged: (v) => setState(() => line.amount = v)),
            if (line.currencyId != widget.localCurrency)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  Expanded(
                    child: Text(
                      'Collect ${neededInCcy.toStringAsFixed(2)} ${line.currencyId} to cover ${remainingLocalExcl.clamp(0.0, double.infinity).toStringAsFixed(2)} ${widget.localCurrency}',
                      style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => line.amount = neededInCcy),
                    style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 24), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    child: const Text('Fill'),
                  ),
                ]),
              ),
            if (line.tenderType == 'CARD' || line.tenderType == 'MOBILE_MONEY')
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextField(
                  decoration: const InputDecoration(isDense: true, labelText: 'Reference No. (optional)', border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 12)),
                  onChanged: (v) => line.referenceNo = v,
                ),
              ),
          ]);

          if (sideBySide) {
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 3, child: modeSelector),
              const SizedBox(width: 20),
              Expanded(flex: 2, child: amountSection),
            ]);
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [modeSelector, const SizedBox(height: 12), amountSection]);
        }),
      ]),
    );
  }
}
