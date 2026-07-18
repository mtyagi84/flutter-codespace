import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/session_provider.dart';
import '../theme/theme_presets.dart';
import '../utils/app_number_format.dart';

/// One line of a [SakalFinancialSummaryCard] — a label/value pair, e.g.
/// ('Subtotal', 1250.00) or ('Discount', -80.00, isNegative: true).
class SakalSummaryRow {
  final String label;
  final double value;
  final bool isNegative;
  const SakalSummaryRow({required this.label, required this.value, this.isNegative = false});
}

/// Shared solid-active-theme-color financial summary block — a document's
/// "grand total" card, white typography throughout, reactive to the live
/// theme preset. Originally built one-off for Sales Invoice's totals;
/// extracted so every other document screen (PO, GRN, Purchase Invoice,
/// Sales Order/Quotation, ...) can adopt the identical treatment instead of
/// each hand-rolling its own totals `Container`.
class SakalFinancialSummaryCard extends ConsumerWidget {
  final String eyebrow;
  final List<SakalSummaryRow> rows;
  final String totalLabel;
  final double total;
  final String currencyCode;

  const SakalFinancialSummaryCard({
    super.key,
    this.eyebrow = 'FINANCIAL SUMMARY',
    required this.rows,
    this.totalLabel = 'GRAND TOTAL',
    required this.total,
    required this.currencyCode,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preset = ThemePresetConfig.all[ref.watch(themePresetProvider)]!;
    final numberFormat = ref.watch(sessionProvider)?.numberFormat ?? 'INTERNATIONAL';

    Widget buildRow(SakalSummaryRow r) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(r.label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
            Text(
              '$currencyCode ${AppNumberFormat.amount(r.value, numberFormat)}',
              style: TextStyle(
                color: r.isNegative ? const Color(0xFFFFCDD2) : Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ]),
        );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: preset.primary,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(eyebrow, style: const TextStyle(color: Colors.white70, fontSize: 10.5, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
        const SizedBox(height: 16),
        ...rows.map(buildRow),
        const Divider(color: Colors.white24, height: 24, thickness: 1),
        Text(totalLabel, style: const TextStyle(color: Colors.white70, fontSize: 10)),
        const SizedBox(height: 4),
        Text(
          '$currencyCode ${AppNumberFormat.amount(total, numberFormat)}',
          style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w900, letterSpacing: -0.5),
        ),
      ]),
    );
  }
}
