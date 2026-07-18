import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/theme_presets.dart';

/// Dark, high-contrast header bar for a document's OWN line-items table
/// (e.g. a Sales Invoice/PO/GRN entry screen's product lines on desktop).
///
/// Deliberately takes a caller-built [cells] list rather than a rigid
/// flex-only column spec: a line-items row is rarely uniform flex columns
/// (it usually mixes a few `Expanded` columns with several fixed-width
/// ones, e.g. a 100px Qty box next to an Expanded Tax column) — the caller
/// wraps each header cell in the exact same `SizedBox`/`Expanded` shape it
/// already uses for its own data row, guaranteeing pixel-perfect column
/// alignment instead of two independently-flexed layouts drifting apart.
/// Use [SakalTableHeaderBar.label] to get the standard header text style
/// for each cell without repeating it at every call site.
///
/// Theme-preset-reactive (near-black by default, matches the confirmed
/// redesign mockup) — separate from [SakalAdaptiveList]'s own internal
/// header, which stays a fixed `AppColors.primary` for its list-screen use.
class SakalTableHeaderBar extends ConsumerWidget {
  final List<Widget> cells;
  const SakalTableHeaderBar({super.key, required this.cells});

  static Widget label(String text, {TextAlign textAlign = TextAlign.left}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
        child: Text(
          text.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: textAlign,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 10.5, letterSpacing: 0.5),
        ),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preset = ThemePresetConfig.all[ref.watch(themePresetProvider)]!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: preset.primary,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: cells),
    );
  }
}
