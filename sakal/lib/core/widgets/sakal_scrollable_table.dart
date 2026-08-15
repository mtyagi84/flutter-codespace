import 'package:flutter/material.dart';

/// Wraps a desktop line-items table's header ([SakalTableHeaderBar]) and
/// its data rows in a single horizontally-scrollable region, sized to
/// whichever is wider: the available viewport, or the table's own natural
/// content width.
///
/// Real gap found 2026-08-07: this session's "Line-items grid" rollout
/// (CLAUDE.md) gave every desktop table a fixed sum of column widths (a
/// table with 8-11 columns easily totals 1200-1400px) but no reflow/scroll
/// strategy — exactly the "Row with no shrink/reflow strategy" bug the
/// Row & Column layout distribution rule exists to prevent, just missed
/// here because a table's columns can't reflow onto multiple lines and
/// stay a valid table the way a form's fields can. Horizontal scroll is
/// the correct fix for THIS shape, not Wrap/SakalFieldRow.
///
/// Header and rows share ONE scroll region (not independent
/// ScrollControllers) so they always stay column-aligned while scrolling
/// — both are children of the same scrolled Column, never synced via two
/// separate scrollables.
///
/// Real gap found live 2026-08-11: the SingleChildScrollView below had no
/// Scrollbar at all — dragging technically worked, but with no visible
/// thumb/track there was no discoverable affordance that the table even
/// scrolled, so columns past the viewport edge (e.g. Department,
/// Consumption Area) read as simply inaccessible. Flutter's default
/// MaterialScrollBehavior only auto-draws a scrollbar on desktop-class
/// platforms, and even then it's a transient hover/drag thumb, not a
/// static one — not reliable on Flutter Web. Fixed with an explicit
/// Scrollbar(thumbVisibility: true, ...) tied to an owned controller, same
/// recipe as the reporting engine's own horizontal scrollbar fix
/// (sakal_report_table.dart).
class SakalScrollableTable extends StatefulWidget {
  final Widget header;
  final List<Widget> rows;

  const SakalScrollableTable({super.key, required this.header, required this.rows});

  @override
  State<SakalScrollableTable> createState() => _SakalScrollableTableState();
}

class _SakalScrollableTableState extends State<SakalScrollableTable> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      return Scrollbar(
        controller: _controller,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          // Real gap found live 2026-08-11: with ConstrainedBox(minWidth:)
          // wrapping IntrinsicWidth (the old order), IntrinsicWidth's own
          // layout tightens its child's constraints to the child's natural
          // width — silently discarding the outer minWidth. Whenever the
          // table's own columns summed to LESS than the viewport (Sales
          // Order: ~828-948px vs. a 1200-1600px desktop), the header/rows
          // stayed at their narrow natural width and left-aligned, while
          // this scroll view still reported the full viewport width —
          // dead space on the right, with the columns never stretching to
          // fill it. Purchase Order's own wider columns (~1650px) never
          // exposed this, since IntrinsicWidth's natural-width value was
          // already >= the viewport minWidth in that case. Swapping the
          // nesting order — IntrinsicWidth now wraps ConstrainedBox,
          // instead of the reverse — lets the minWidth constraint reach
          // the Column before IntrinsicWidth's own measurement pass, so it
          // actually stretches to fill the viewport when narrower, while
          // still growing normally (and scrolling, via the Scrollbar
          // above) when the table's natural content is wider.
          child: IntrinsicWidth(
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              // Trailing gap so the horizontal scrollbar's own track/thumb
              // doesn't render flush against the last row's bottom edge —
              // found live 2026-08-16, read as the scrollbar "touching"
              // the last line.
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [widget.header, ...widget.rows, const SizedBox(height: 10)]),
            ),
          ),
        ),
      );
    });
  }
}
