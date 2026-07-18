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
/// Three distinct visual states, not two — a real gap found live: every
/// editable field's `child` uses [bareDecoration] (`InputBorder.none` on
/// EVERY border state, including `focusedBorder`), so the inner
/// TextFormField/SakalAutocomplete/DropdownButtonFormField has ZERO native
/// focus feedback — the only border came from this card's own `editable`
/// flag, identical whether the field was merely editABLE or actually the
/// one currently being typed into, which a real user found genuinely
/// confusing ("which field am I in?"). Fixed by tracking focus internally:
/// [child] is wrapped in a non-focusable ancestor `Focus` node whose
/// `hasFocus` becomes true whenever ANY descendant gains focus (Flutter's
/// own documented `FocusNode.hasFocus` semantics: true for the node
/// itself OR any node in the current primary focus's ancestor chain) —
/// zero call-site changes needed, existing/implicit FocusNodes on the
/// child widgets keep working exactly as before. Read-only < editable-
/// idle < editable-focused, each visually distinct.
///
/// Density-aware by default: height follows the active
/// [isCompactDensityProvider] setting (40px dense / 54px comfortable) so
/// "Dense" mode compacts every field on a screen, not just literal
/// SakalAdaptiveList table rows — pass [height] to opt a specific field out
/// (e.g. a multi-line remarks box) of that automatic sizing. Label font
/// size, the label/value gap, and vertical padding all shrink together in
/// dense mode too — a real bug found live: the label(10px)+gap(2)+value
/// (14px) stack plus 12px of padding (33-34px) came within a hair of the
/// 40px dense height even at "comfortable" sizing, and reliably clipped
/// once Flutter's actual line-height (never exactly the font-size number)
/// was added in — dense mode needs the WHOLE stack to shrink, not just the
/// outer box.
class SakalFieldCard extends ConsumerStatefulWidget {
  final String label;
  final bool required;
  final bool editable;
  final Widget? child;
  final String? value;
  final double? height;

  const SakalFieldCard({
    super.key,
    required this.label,
    required this.child,
    this.required = false,
    this.editable = false,
    this.height,
  }) : value = null;

  /// Convenience constructor for a plain read-only text value — Location,
  /// Currency-when-locked, a computed line amount, etc. Kept as a `value`
  /// string rather than a pre-built `Text` so its style can be resolved at
  /// build time (density-aware), not frozen at construction time.
  const SakalFieldCard.readOnly({
    super.key,
    required this.label,
    required this.value,
    this.required = false,
    this.height,
  })  : editable = false,
        child = null;

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

  /// The value/input text style every editable field's own `child` should
  /// be given (via its `style:` param) to match what this card renders for
  /// a `.readOnly()` value — density-aware, so a caller doesn't have to
  /// hand-roll its own dense/comfortable font-size switch. Callers compute
  /// `isCompact` themselves (`ref.watch(isCompactDensityProvider)`) since a
  /// child widget built outside this widget's own `build()` has no other
  /// way to know it.
  static TextStyle valueTextStyle(bool isCompact) => TextStyle(
        fontSize: isCompact ? 12 : 14,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
      );

  @override
  ConsumerState<SakalFieldCard> createState() => _SakalFieldCardState();
}

class _SakalFieldCardState extends ConsumerState<SakalFieldCard> {
  late final FocusNode _focusWithinNode;

  @override
  void initState() {
    super.initState();
    // canRequestFocus: false / skipTraversal: true — this node never
    // becomes the primary focus itself; it exists purely as an ancestor
    // marker so hasFocus reflects whatever descendant field currently has
    // real focus.
    _focusWithinNode = FocusNode(canRequestFocus: false, skipTraversal: true, debugLabel: 'SakalFieldCard(${widget.label})');
    _focusWithinNode.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _focusWithinNode.removeListener(_onFocusChange);
    _focusWithinNode.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isCompact = ref.watch(isCompactDensityProvider);
    final preset = ThemePresetConfig.all[ref.watch(themePresetProvider)]!;
    final resolvedHeight = widget.height ?? DensityMetrics.of(isCompact).rowHeight;
    final isFocused = widget.editable && _focusWithinNode.hasFocus;
    final labelFontSize = isCompact ? 8.5 : 10.0;
    final gap = isCompact ? 1.0 : 2.0;
    final vPad = isCompact ? 3.0 : 6.0;

    final Color borderColor;
    final double borderWidth;
    if (isFocused) {
      borderColor = preset.secondary;
      borderWidth = 2;
    } else if (widget.editable) {
      borderColor = AppColors.textDisabled;
      borderWidth = 1;
    } else {
      borderColor = AppColors.border;
      borderWidth = 1;
    }

    final content = widget.child ??
        Text(
          widget.value!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: SakalFieldCard.valueTextStyle(isCompact),
        );

    return Focus(
      focusNode: _focusWithinNode,
      child: Container(
        height: resolvedHeight,
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: vPad),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: borderColor, width: borderWidth),
          boxShadow: isFocused
              ? [BoxShadow(color: preset.secondary.withValues(alpha: 0.14), blurRadius: 0, spreadRadius: 3)]
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RichText(
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              text: TextSpan(
                text: widget.label.toUpperCase(),
                style: TextStyle(fontSize: labelFontSize, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: AppColors.textSecondary),
                children: widget.required
                    ? const [TextSpan(text: ' *', style: TextStyle(color: AppColors.negative, fontWeight: FontWeight.w700))]
                    : null,
              ),
            ),
            SizedBox(height: gap),
            Expanded(child: Align(alignment: Alignment.centerLeft, child: content)),
          ],
        ),
      ),
    );
  }
}
