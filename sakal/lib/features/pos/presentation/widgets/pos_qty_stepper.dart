import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import 'pos_numpad.dart';

/// `[-]  qty  [+]` — the touch-first replacement for a raw Qty `TextField`
/// on a POS cart/return line. The common case (bump by 1) never needs the
/// keypad at all; tapping the number itself opens `PosNumpad` for a precise
/// or fractional value (e.g. a weighted item).
class PosQtyStepper extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;
  final double step;
  final double min;
  final bool enabled;
  final double buttonSize;

  const PosQtyStepper({
    super.key,
    required this.value,
    required this.onChanged,
    this.step = 1,
    this.min = 0,
    this.enabled = true,
    this.buttonSize = 44,
  });

  static String _trim(double v) {
    var s = v.toStringAsFixed(4);
    s = s.contains('.') ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '') : s;
    return s;
  }

  void _bump(double delta) {
    final next = value + delta;
    onChanged(next < min ? min : next);
  }

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _StepButton(icon: Icons.remove, size: buttonSize, onTap: enabled ? () => _bump(-step) : null),
      Expanded(
        child: InkWell(
          onTap: enabled
              ? () => PosNumpad.show(
                    context,
                    title: 'Quantity',
                    initialValue: value,
                    onConfirm: onChanged,
                  )
              : null,
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: FittedBox(fit: BoxFit.scaleDown, child: Text(_trim(value), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800))),
          ),
        ),
      ),
      _StepButton(icon: Icons.add, size: buttonSize, onTap: enabled ? () => _bump(step) : null),
    ]);
  }
}

class _StepButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final VoidCallback? onTap;
  const _StepButton({required this.icon, required this.size, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Material(
      color: disabled ? AppColors.background : AppColors.primary.withValues(alpha: 0.08),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: size * 0.45, color: disabled ? AppColors.border : AppColors.primary),
        ),
      ),
    );
  }
}
