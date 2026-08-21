import 'package:flutter/material.dart';

/// Shared responsive field-reflow row — the pair widget to [SakalFieldRow]
/// (`sakal_field_row.dart`). Where `SakalFieldRow` fits a small, fixed set
/// of fields into ONE row by compressing them (`Expanded`/flex), this
/// widget is for a larger or variable-count set of fields (e.g. a report
/// filter bar) that must instead REFLOW onto additional rows when they
/// don't all fit — `Row`/`Expanded` can never wrap to a new line, and a
/// plain `Wrap` has no stretch mechanism, so a fixed-pixel-width child
/// leaves dead trailing space on any row it doesn't exactly fill.
///
/// Computes how many weighted "units" fit per row at [minChildWidth], then
/// sizes every child as a share of whatever's actually available — fields
/// fill each row edge-to-edge instead of leaving dead space to the right,
/// and still wrap onto a new row on a narrow/tablet screen. Extracted from
/// `sakal_report_filter_bar.dart`'s own inlined version of this same logic
/// (see the Responsive Layout & Field Distribution section of
/// design_system_guide.md for the full decision table of when to use this
/// vs. [SakalFieldRow] vs. a plain `Wrap`).
class SakalReflowRow extends StatelessWidget {
  final List<Widget> children;

  /// Relative weight per child, parallel to [children]. A child needing
  /// roughly double a plain field's width (e.g. a date-range pair) gets
  /// 2.0; omit for equal weighting (1.0 each).
  final List<double>? flexWeights;

  final double minChildWidth;
  final double spacing;
  final double runSpacing;

  const SakalReflowRow({
    super.key,
    required this.children,
    this.flexWeights,
    this.minChildWidth = 200,
    this.spacing = 12,
    this.runSpacing = 12,
  });

  double _weightFor(int i) => (flexWeights != null && i < flexWeights!.length) ? flexWeights![i] : 1.0;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, constraints) {
      final totalWidth = constraints.maxWidth.isFinite ? constraints.maxWidth : 1000.0;
      final unitsPerRow = (totalWidth / minChildWidth).floor().clamp(1, 999);

      // Group children into real rows first (matching how many whole
      // minChildWidth-sized units actually fit), THEN size each row's own
      // children as a share of that row's real width via Expanded/flex —
      // never a single global width estimate applied uniformly to every
      // child regardless of how many end up sharing its actual row. That
      // old two-pass approach (estimate width, then hand off to Wrap's own
      // independent line-breaking) could disagree with Wrap's real greedy
      // break, leaving dead trailing space on a row Wrap only fit one
      // field into — the exact bug reported on narrow/mobile screens.
      final rows = <List<int>>[];
      var current = <int>[];
      var currentWeight = 0.0;
      for (var i = 0; i < children.length; i++) {
        final w = _weightFor(i);
        if (current.isNotEmpty && currentWeight + w > unitsPerRow) {
          rows.add(current);
          current = [];
          currentWeight = 0;
        }
        current.add(i);
        currentWeight += w;
      }
      if (current.isNotEmpty) rows.add(current);

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var r = 0; r < rows.length; r++) ...[
            if (r > 0) SizedBox(height: runSpacing),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                for (var j = 0; j < rows[r].length; j++) ...[
                  if (j > 0) SizedBox(width: spacing),
                  Expanded(
                    flex: (_weightFor(rows[r][j]) * 100).round(),
                    child: children[rows[r][j]],
                  ),
                ],
              ],
            ),
          ],
        ],
      );
    });
  }
}
