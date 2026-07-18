import 'package:flutter/material.dart';

/// Shared responsive field row — the fix for a real complaint on the
/// confirmed redesign mockup: a header/form row built as
/// `Wrap(children: [SizedBox(width: 200, ...), ...])` looks fine when the
/// fields happen to fill the row, but leaves a large empty gap on the
/// right on any wider screen, since `Wrap` never stretches a child to fill
/// leftover row space no matter how much is visibly unused.
///
/// Column model follows Oracle APEX's 12-column grid, per user request:
/// every row is 12 units wide, and [spans] gives each child's own width in
/// those units (2 children at 6 each, 3 at 4 each, 4 at 3 each, ...).
/// Omit [spans] (the common case) to divide the row EQUALLY among however
/// many children there are — `Expanded(flex: 1)` per child achieves this
/// without needing the spans to literally sum to 12 (a Row's flex weights
/// are always relative to each other, not absolute), so equal division
/// works for any child count, not just factors of 12. When [spans] IS
/// given, its values should sum to 12 for a single row to fill the width
/// exactly as an APEX developer would expect; nothing here enforces that
/// sum, since a caller with a specific reason to under/overshoot it
/// (e.g. deliberately leaving trailing empty space) shouldn't be blocked.
///
/// On desktop, lays [children] into a `Row` where each one is `Expanded`
/// with its own span. On mobile ([isMobile]), stacks them full-width in a
/// `Column` instead — matching the existing `isMobile ? double.infinity :
/// <fixed>` convention every entry screen already uses for its own
/// fields, just without a screen having to hand-roll the Row/Column switch
/// itself.
class SakalFieldRow extends StatelessWidget {
  final bool isMobile;
  final List<Widget> children;
  final List<int>? spans;
  final double spacing;

  const SakalFieldRow({
    super.key,
    required this.isMobile,
    required this.children,
    this.spans,
    this.spacing = 16,
  });

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();

    if (isMobile) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(height: spacing * 0.75),
          children[i],
        ],
      ]);
    }

    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) SizedBox(width: spacing),
        Expanded(flex: (spans != null && i < spans!.length) ? spans![i] : 1, child: children[i]),
      ],
    ]);
  }
}
