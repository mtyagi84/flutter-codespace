import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../core/theme/app_colors.dart';
import 'pos_numpad.dart';

/// A real `TextField` (numeric) styled to match POS's touch-first look —
/// NOT a tap-opens-a-sheet-only button anymore. Real bug found live
/// 2026-10-11 (same root cause as `PosKeyboardField`'s own fix): this
/// widget's old doc comment said "No OS/browser keyboard is ever invoked"
/// as a DELIBERATE design choice — meaning a physical keyboard/numpad had
/// nothing to type into, on EVERY rate/qty/discount/amount field across
/// POS (New Sale, Shift opening float, Cash Movement, Close Shift counted
/// amount, Return qty, ...). Now a real numeric `TextField`, so a physical
/// keyboard and the OS's own on-screen numeric keyboard both just work;
/// `PosNumpad`'s large-tap-target sheet is kept as an OPTIONAL secondary
/// input method (the small numpad icon button), never required.
class PosAmountField extends StatefulWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final String? suffixText;
  final bool allowDecimal;
  final bool enabled;
  final bool compact;
  final int decimals;
  final bool showTouchNumpadButton;

  const PosAmountField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.suffixText,
    this.allowDecimal = true,
    this.enabled = true,
    this.compact = false,
    this.decimals = 2,
    this.showTouchNumpadButton = true,
  });

  @override
  State<PosAmountField> createState() => _PosAmountFieldState();
}

class _PosAmountFieldState extends State<PosAmountField> {
  late final TextEditingController _controller = TextEditingController(text: _format(widget.value));
  late final FocusNode _focusNode = FocusNode();

  String _format(double v) => v == 0 ? '' : (v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(widget.decimals));

  @override
  void didUpdateWidget(covariant PosAmountField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only resync from an EXTERNAL change (e.g. a parent recomputing this
    // value from other fields) — never while this field itself still has
    // focus, which would fight the user's own in-progress typing/cursor.
    if (widget.value != oldWidget.value && !_focusNode.hasFocus) {
      final formatted = _format(widget.value);
      if (formatted != _controller.text) {
        _controller.value = _controller.value.copyWith(text: formatted, selection: TextSelection.collapsed(offset: formatted.length));
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    widget.onChanged(double.tryParse(v) ?? 0);
  }

  void _openTouchNumpad() {
    PosNumpad.show(
      context,
      title: widget.label,
      initialValue: double.tryParse(_controller.text) ?? widget.value,
      suffixText: widget.suffixText,
      allowDecimal: widget.allowDecimal,
      onConfirm: (v) {
        final formatted = _format(v);
        _controller.value = _controller.value.copyWith(text: formatted, selection: TextSelection.collapsed(offset: formatted.length));
        widget.onChanged(v);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      enabled: widget.enabled,
      onChanged: _onChanged,
      keyboardType: TextInputType.numberWithOptions(decimal: widget.allowDecimal, signed: false),
      inputFormatters: [
        widget.allowDecimal
            ? FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*'))
            : FilteringTextInputFormatter.digitsOnly,
      ],
      textAlign: TextAlign.left,
      style: TextStyle(fontSize: widget.compact ? 14 : 17, fontWeight: FontWeight.w700, color: widget.enabled ? AppColors.textPrimary : AppColors.textSecondary),
      decoration: InputDecoration(
        labelText: widget.label,
        labelStyle: const TextStyle(fontSize: 11),
        suffixText: widget.suffixText,
        suffixStyle: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
        suffixIcon: widget.showTouchNumpadButton && widget.enabled
            ? IconButton(
                icon: const Icon(Icons.dialpad, size: 18),
                tooltip: 'Open touch numpad',
                onPressed: _openTouchNumpad,
              )
            : null,
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: widget.compact ? 8 : 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
        filled: !widget.enabled,
        fillColor: AppColors.background,
      ),
    );
  }
}
