import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import 'sakal_field_card.dart';

/// A rate-entry field that always holds and uses the literal,
/// always-multiply-ready value — no hidden inversion between what's
/// displayed and what's actually multiplied, unlike the older Finance
/// Voucher screen's own rate field (see docs/screens/journal_voucher.md).
///
/// For this app's real currency pairs (base=USD against a weak local
/// currency like CDF/ZMW), the always-multiply rate is normally a tiny
/// decimal (e.g. 0.0004) — hard to type precisely. A small `@` icon
/// appears only when the current value is `< 1`; tapping it opens a
/// popup showing the reciprocal (the "easy" number, e.g. 2500) in its
/// own editable field. Confirming recomputes `1 / entered` and writes
/// it back into this field — the popup is a pure data-entry aid, never
/// a second source of truth. The main field's value is always what
/// actually gets multiplied.
class SakalReciprocalRateField extends StatelessWidget {
  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onEditingComplete;

  const SakalReciprocalRateField({
    super.key,
    required this.controller,
    this.enabled = true,
    this.onChanged,
    this.onEditingComplete,
  });

  Future<void> _openReciprocalPopup(BuildContext context) async {
    final current = double.tryParse(controller.text) ?? 0;
    if (current <= 0) return;
    final reciprocalCtrl = TextEditingController(text: _trimZeros(1 / current));

    final result = await showDialog<double>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Enter Reciprocal Rate'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Type the easier, larger number — it will be converted back automatically.', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          TextField(
            controller: reciprocalCtrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*'))],
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final entered = double.tryParse(reciprocalCtrl.text);
              if (entered == null || entered <= 0) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(content: Text('Enter a positive number.'), backgroundColor: Colors.orange),
                );
                return;
              }
              Navigator.of(dialogContext, rootNavigator: true).pop(1 / entered);
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    reciprocalCtrl.dispose();

    if (result != null) {
      final text = _trimZeros(result);
      controller.text = text;
      onChanged?.call(text);
    }
  }

  static String _trimZeros(double v) {
    var s = v.toStringAsFixed(10);
    s = s.contains('.') ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '') : s;
    return s;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final current = double.tryParse(value.text);
        final showReciprocalIcon = current != null && current > 0 && current < 1;
        return TextFormField(
          controller: controller,
          enabled: enabled,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*'))],
          onChanged: onChanged,
          onEditingComplete: onEditingComplete,
          decoration: SakalFieldCard.bareDecoration.copyWith(
            suffixIcon: showReciprocalIcon
                ? Tooltip(
                    message: 'Enter as reciprocal (easier number)',
                    child: IconButton(
                      icon: const Icon(Icons.alternate_email, size: 16),
                      color: AppColors.secondary,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: enabled ? () => _openReciprocalPopup(context) : null,
                    ),
                  )
                : null,
          ),
        );
      },
    );
  }
}
