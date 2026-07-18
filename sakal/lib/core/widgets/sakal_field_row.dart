import 'package:flutter/material.dart';

/// Shared responsive field row — the fix for a real complaint on the
/// confirmed redesign mockup: a header/form row built as
/// `Wrap(children: [SizedBox(width: 200, ...), ...])` looks fine when the
/// fields happen to fill the row, but leaves a large empty gap on the
/// right on any wider screen, since `Wrap` never stretches a child to fill
/// leftover row space no matter how much is visibly unused.
///
/// On desktop, lays [children] into a `Row` where each one is `Expanded`
/// (optionally weighted via [flexes]) so they always fill the full row
/// width. On mobile ([isMobile]), stacks them full-width in a `Column`
/// instead — matching the existing `isMobile ? double.infinity : <fixed>`
/// convention every entry screen already uses for its own fields, just
/// without a screen having to hand-roll the Row/Column switch itself.
class SakalFieldRow extends StatelessWidget {
  final bool isMobile;
  final List<Widget> children;
  final List<int>? flexes;
  final double spacing;

  const SakalFieldRow({
    super.key,
    required this.isMobile,
    required this.children,
    this.flexes,
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
        Expanded(flex: (flexes != null && i < flexes!.length) ? flexes![i] : 1, child: children[i]),
      ],
    ]);
  }
}
