import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/app_colors.dart';
import '../theme/theme_presets.dart';

/// Shared "label above bold value" field shell — the confirmed Sales
/// Invoice mockup's `.stat`/`.stat.editable` pattern. Every header/line
/// field on a redesigned screen (a plain read-only value OR a live input)
/// renders inside one of these so height/border/typography stay identical
/// regardless of what's inside, instead of every screen hand-rolling its
/// own `InputDecorator`/`TextFormField` border treatment.
///
/// Density-aware by default: height follows the active
/// [isCompactDensityProvider] setting (40px dense / 54px comfortable) so
/// "Dense" mode compacts every field on a screen, not just literal
/// SakalAdaptiveList table rows — pass [height] to opt a specific field out
/// (e.g. a multi-line remarks box) of that automatic sizing.
class SakalFieldCard extends ConsumerWidget {
  final String label;
  final bool required;
  final bool editable;
  final Widget child;
  final double? height;

  const SakalFieldCard({
    super.key,
    required this.label,
    required this.child,
    this.required = false,
    this.editable = false,
    this.height,
  });

  /// Convenience factory for a plain read-only text value — Location,
  /// Currency-when-locked, a computed line amount, etc.
  factory SakalFieldCard.readOnly({
    Key? key,
    required String label,
    required String value,
    bool required = false,
    double? height,
  }) {
    return SakalFieldCard(
      key: key,
      label: label,
      required: required,
      height: height,
      child: Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
      ),
    );
  }

  /// Decoration to give any input nested as this card's [child]
  /// (TextFormField / DropdownButtonFormField / SakalAutocomplete) — strips
  /// the input's own border/label/fill so the CARD draws all the chrome and
  /// the input only ever handles text. No label here on purpose:
  /// SakalFieldCard renders its own static label above the value, never a
  /// floating Material label.
  static const InputDecoration bareDecoration = InputDecoration(
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    disabledBorder: InputBorder.none,
    errorBorder: InputBorder.none,
    focusedErrorBorder: InputBorder.none,
    filled: false,
    isDense: true,
    isCollapsed: true,
    contentPadding: EdgeInsets.zero,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCompact = ref.watch(isCompactDensityProvider);
    final preset = ThemePresetConfig.all[ref.watch(themePresetProvider)]!;
    final resolvedHeight = height ?? DensityMetrics.of(isCompact).rowHeight;
    final borderColor = editable ? preset.secondary : AppColors.border;

    return Container(
      height: resolvedHeight,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: borderColor, width: editable ? 1.4 : 1),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RichText(
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              text: label.toUpperCase(),
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: AppColors.textSecondary),
              children: required
                  ? const [TextSpan(text: ' *', style: TextStyle(color: AppColors.negative, fontWeight: FontWeight.w700))]
                  : null,
            ),
          ),
          const SizedBox(height: 2),
          Expanded(child: Align(alignment: Alignment.centerLeft, child: child)),
        ],
      ),
    );
  }
}
