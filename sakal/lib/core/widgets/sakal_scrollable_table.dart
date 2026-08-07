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
class SakalScrollableTable extends StatelessWidget {
  final Widget header;
  final List<Widget> rows;

  const SakalScrollableTable({super.key, required this.header, required this.rows});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: IntrinsicWidth(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [header, ...rows]),
          ),
        ),
      );
    });
  }
}
