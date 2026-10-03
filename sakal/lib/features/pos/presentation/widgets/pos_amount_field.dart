import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import 'pos_numpad.dart';

/// The touch-first replacement for a raw `TextField` on any money/qty/percent
/// value in POS. Renders as a large, bordered, tappable "display box" (label
/// above, current value big and right-aligned) — tapping it opens
/// `PosNumpad` in a bottom sheet; the field's own value only ever changes
/// once the user taps Done there. No OS/browser keyboard is ever invoked.
class PosAmountField extends StatelessWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final String? suffixText;
  final bool allowDecimal;
  final bool enabled;
  final bool compact;

  const PosAmountField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.suffixText,
    this.allowDecimal = true,
    this.enabled = true,
    this.compact = false,
  });

  static String _trim(double v) {
    var s = v.toStringAsFixed(4);
    s = s.contains('.') ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '') : s;
    return s;
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: enabled ? Colors.white : AppColors.background,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: enabled
            ? () => PosNumpad.show(
                  context,
                  title: label,
                  initialValue: value,
                  suffixText: suffixText,
                  allowDecimal: allowDecimal,
                  onConfirm: onChanged,
                )
            : null,
        child: Container(
          constraints: BoxConstraints(minHeight: compact ? 44 : 52),
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: compact ? 4 : 8),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, color: AppColors.textSecondary)),
            const SizedBox(height: 1),
            Row(children: [
              // FittedBox shrinks the value to fit rather than ever wrapping
              // onto a second line — a long amount (e.g. a Rate with many
              // digits) was found live wrapping and bloating the row height.
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(_trim(value), maxLines: 1, style: TextStyle(fontSize: compact ? 14 : 17, fontWeight: FontWeight.w700, color: enabled ? AppColors.textPrimary : AppColors.textSecondary)),
                ),
              ),
              if (suffixText != null) Text(suffixText!, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            ]),
          ]),
        ),
      ),
    );
  }
}
