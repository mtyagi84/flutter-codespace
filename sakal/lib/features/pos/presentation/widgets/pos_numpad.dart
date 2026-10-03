import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../core/theme/app_colors.dart';

/// A large, touch-first numeric keypad for AMOUNT/QTY/PERCENT entry —
/// the `PosAmountField`/`PosQtyStepper` counterpart to `PosPinPad`'s own
/// digit grid. Deliberately builds its value from scratch via explicit
/// digit-button taps, never from a raw `TextField` — this is what makes the
/// "field defaults to '0', typing inserts digits around it instead of
/// replacing it" class of bug (found live on Open Shift) structurally
/// impossible here, not just patched.
///
/// Self-contained: shown via `showModalBottomSheet`, carries its own buffer
/// and a live preview, and only ever hands the parent a final parsed
/// `double` on Done — the parent never sees intermediate keystrokes.
class PosNumpad extends StatefulWidget {
  final String title;
  final double? initialValue;
  final String? suffixText;
  final bool allowDecimal;
  final ValueChanged<double> onConfirm;

  const PosNumpad({
    super.key,
    required this.title,
    this.initialValue,
    this.suffixText,
    this.allowDecimal = true,
    required this.onConfirm,
  });

  @override
  State<PosNumpad> createState() => _PosNumpadState();

  /// Convenience launcher — shows this widget in a bottom sheet and returns
  /// once dismissed. Every POS screen should call this rather than
  /// constructing `showModalBottomSheet` by hand, so the sheet shape (sized,
  /// rounded top, scroll-safe) stays identical everywhere.
  static Future<void> show(
    BuildContext context, {
    required String title,
    double? initialValue,
    String? suffixText,
    bool allowDecimal = true,
    required ValueChanged<double> onConfirm,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetContext) => ConstrainedBox(
        // A short viewport (small laptop window, landscape phone) could not
        // fit this content before — confirmed live, "BOTTOM OVERFLOWED BY
        // 112 PIXELS". Capping height + wrapping in a scroll view makes the
        // sheet degrade to scrollable instead of ever overflowing.
        constraints: BoxConstraints(maxHeight: MediaQuery.of(sheetContext).size.height * 0.85),
        child: SingleChildScrollView(
          padding: EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
          child: PosNumpad(title: title, initialValue: initialValue, suffixText: suffixText, allowDecimal: allowDecimal, onConfirm: onConfirm),
        ),
      ),
    );
  }
}

class _PosNumpadState extends State<PosNumpad> {
  late String _buffer;

  @override
  void initState() {
    super.initState();
    final v = widget.initialValue;
    _buffer = (v == null || v == 0) ? '' : _trim(v);
  }

  static String _trim(double v) {
    var s = v.toStringAsFixed(4);
    s = s.contains('.') ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '') : s;
    return s;
  }

  void _digit(String d) {
    if (_buffer.length >= 12) return;
    setState(() => _buffer += d);
  }

  void _decimal() {
    if (!widget.allowDecimal || _buffer.contains('.')) return;
    setState(() => _buffer = _buffer.isEmpty ? '0.' : '$_buffer.');
  }

  void _backspace() {
    if (_buffer.isEmpty) return;
    setState(() => _buffer = _buffer.substring(0, _buffer.length - 1));
  }

  void _clear() => setState(() => _buffer = '');

  void _confirm() {
    final value = double.tryParse(_buffer) ?? 0;
    widget.onConfirm(value);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 14),
        Row(children: [
          const SizedBox(width: 48),
          Expanded(
            child: Text(widget.title, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.textSecondary)),
          ),
          TextButton(onPressed: _clear, child: const Text('Clear')),
        ]),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
          child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            Flexible(
              child: Text(
                _buffer.isEmpty ? '0' : _buffer,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
              ),
            ),
            if (widget.suffixText != null) ...[
              const SizedBox(width: 8),
              Text(widget.suffixText!, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
            ],
          ]),
        ),
        const SizedBox(height: 16),
        _NumGrid(allowDecimal: widget.allowDecimal, onDigit: _digit, onDecimal: _decimal, onBackspace: _backspace),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(onPressed: _confirm, icon: const Icon(Icons.check), label: const Text('Done')),
        ),
      ]),
    );
  }
}

class _NumGrid extends StatelessWidget {
  final bool allowDecimal;
  final ValueChanged<String> onDigit;
  final VoidCallback onDecimal;
  final VoidCallback onBackspace;

  const _NumGrid({required this.allowDecimal, required this.onDigit, required this.onDecimal, required this.onBackspace});

  @override
  Widget build(BuildContext context) {
    Widget key(String label, {VoidCallback? onTap, bool muted = false, bool disabled = false}) => _NumKey(
          label: label,
          muted: muted,
          onTap: disabled ? null : (onTap ?? () {
            HapticFeedback.selectionClick();
            onDigit(label);
          }),
        );

    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.6,
      children: [
        key('1'), key('2'), key('3'),
        key('4'), key('5'), key('6'),
        key('7'), key('8'), key('9'),
        key('.', onTap: onDecimal, muted: true, disabled: !allowDecimal),
        key('0'),
        key('⌫', onTap: onBackspace, muted: true),
      ],
    );
  }
}

class _NumKey extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool muted;

  const _NumKey({required this.label, required this.onTap, required this.muted});

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Material(
      color: AppColors.background,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: muted ? 14 : 22,
              fontWeight: muted ? FontWeight.w600 : FontWeight.w700,
              color: disabled ? AppColors.border : (muted ? AppColors.textSecondary : AppColors.textPrimary),
            ),
          ),
        ),
      ),
    );
  }
}
