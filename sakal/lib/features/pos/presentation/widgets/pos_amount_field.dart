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

  const PosAmountField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.suffixText,
    this.allowDecimal = true,
    this.enabled = true,
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
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            const SizedBox(height: 2),
            Row(children: [
              Expanded(child: Text(_trim(value), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: enabled ? AppColors.textPrimary : AppColors.textSecondary))),
              if (suffixText != null) Text(suffixText!, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            ]),
          ]),
        ),
      ),
    );
  }
}
