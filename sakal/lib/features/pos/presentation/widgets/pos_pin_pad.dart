import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../core/theme/app_colors.dart';

/// A large, touch-first numeric keypad for PIN entry — shared by the PIN
/// login screen, the idle-lock overlay, and the real-time supervisor
/// override modal (see docs/pos/mockups/01_login.html, 13_supervisor_
/// override.html, 14_idle_lock.html — all three use the identical keypad,
/// so this widget is the one real implementation behind all of them).
///
/// Deliberately NOT a text field: a physical/on-screen keyboard is exactly
/// what this widget exists to avoid (see docs/pos/06_access_security.md §4 —
/// "PIN-only, no password UI anywhere on the till"). [length] is the number
/// of dots/digits to collect — callers read it from the company's own
/// `pos_pin_length` setting rather than hardcoding 4, so a different
/// deployment's PIN policy needs no code change.
class PosPinPad extends StatefulWidget {
  final int length;
  final ValueChanged<String> onSubmitted;
  final bool enabled;

  const PosPinPad({
    super.key,
    required this.length,
    required this.onSubmitted,
    this.enabled = true,
  });

  @override
  State<PosPinPad> createState() => PosPinPadState();
}

class PosPinPadState extends State<PosPinPad> {
  String _entered = '';

  /// Called externally (e.g. after a failed attempt) to clear the dots
  /// without the caller needing to rebuild this whole widget with a new key.
  void clear() => setState(() => _entered = '');

  void _tap(String digit) {
    if (!widget.enabled || _entered.length >= widget.length) return;
    setState(() => _entered += digit);
    if (_entered.length == widget.length) {
      final pin = _entered;
      // Clear immediately so a second tap (or a failed-attempt retry)
      // never appends onto an already-submitted PIN.
      setState(() => _entered = '');
      widget.onSubmitted(pin);
    }
  }

  void _backspace() {
    if (!widget.enabled || _entered.isEmpty) return;
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(widget.length, (i) {
            final filled = i < _entered.length;
            return Container(
              width: 16,
              height: 16,
              margin: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: filled ? AppColors.primary : Colors.transparent,
                border: Border.all(color: filled ? AppColors.primary : AppColors.border, width: 2),
              ),
            );
          }),
        ),
        const SizedBox(height: 18),
        _KeyGrid(onDigit: _tap, onBackspace: _backspace, onClear: () => setState(() => _entered = ''), enabled: widget.enabled),
      ],
    );
  }
}

class _KeyGrid extends StatelessWidget {
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final VoidCallback onClear;
  final bool enabled;

  const _KeyGrid({required this.onDigit, required this.onBackspace, required this.onClear, required this.enabled});

  @override
  Widget build(BuildContext context) {
    Widget key(String label, {VoidCallback? onTap, bool wide = false}) => _PinKey(
          label: label,
          wide: wide,
          enabled: enabled,
          onTap: onTap ?? () {
            HapticFeedback.selectionClick();
            onDigit(label);
          },
        );

    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.5,
      children: [
        key('1'), key('2'), key('3'),
        key('4'), key('5'), key('6'),
        key('7'), key('8'), key('9'),
        key('Clear', wide: true, onTap: onClear),
        key('0'),
        key('⌫', wide: true, onTap: onBackspace),
      ],
    );
  }
}

class _PinKey extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool wide;
  final bool enabled;

  const _PinKey({required this.label, required this.onTap, required this.wide, required this.enabled});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.background,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: enabled ? onTap : null,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: wide ? 13 : 20,
              fontWeight: wide ? FontWeight.w600 : FontWeight.w700,
              color: wide ? AppColors.textSecondary : AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
