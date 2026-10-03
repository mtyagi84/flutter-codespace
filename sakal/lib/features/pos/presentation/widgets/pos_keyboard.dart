import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';

/// A compact, touch-first on-screen QWERTY — deliberately simple (lowercase
/// + Shift for caps, Space, Backspace, Done), not a general-purpose IME. Used
/// ONLY as an explicit, visible fallback for free-text search fields whose
/// primary flow is scan-first (a barcode scanner needs no on-screen UI at
/// all) — e.g. Return's manual invoice-number search, Price Check's manual
/// SKU search. Never the default interaction for those fields.
const _kKeyboardRows = [
  ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
  ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'],
  ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'],
  ['z', 'x', 'c', 'v', 'b', 'n', 'm'],
];

class PosKeyboard extends StatefulWidget {
  final String title;
  final String? initialValue;
  final ValueChanged<String> onConfirm;
  final bool obscureText;
  /// Fires on every keystroke — lets a caller do LIVE filtering (e.g. a
  /// customer search list) while the sheet stays open, unlike `onConfirm`
  /// which only fires once on Done.
  final ValueChanged<String>? onChanged;

  const PosKeyboard({super.key, required this.title, this.initialValue, required this.onConfirm, this.obscureText = false, this.onChanged});

  @override
  State<PosKeyboard> createState() => _PosKeyboardState();

  /// Shows this widget in a bottom sheet, same "sheet shape" convention as
  /// `PosNumpad.show`.
  static Future<void> show(
    BuildContext context, {
    required String title,
    String? initialValue,
    required ValueChanged<String> onConfirm,
    bool obscureText = false,
    ValueChanged<String>? onChanged,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
        // Fixed height, Done pinned as a sibling of the (internally
        // scrollable) key grid — same fix as PosNumpad; Done used to live
        // inside one big scroll view and could scroll out of reach on a
        // short viewport.
        child: SizedBox(
          height: MediaQuery.of(sheetContext).size.height * 0.9,
          child: PosKeyboard(title: title, initialValue: initialValue, onConfirm: onConfirm, obscureText: obscureText, onChanged: onChanged),
        ),
      ),
    );
  }
}

class _PosKeyboardState extends State<PosKeyboard> {
  late String _buffer;
  bool _shift = false;

  @override
  void initState() {
    super.initState();
    _buffer = widget.initialValue ?? '';
  }

  void _notify() => widget.onChanged?.call(_buffer);

  void _type(String ch) {
    setState(() => _buffer += _shift ? ch.toUpperCase() : ch);
    _notify();
  }
  void _space() {
    setState(() => _buffer += ' ');
    _notify();
  }
  void _backspace() {
    if (_buffer.isEmpty) return;
    setState(() => _buffer = _buffer.substring(0, _buffer.length - 1));
    _notify();
  }
  void _clear() {
    setState(() => _buffer = '');
    _notify();
  }
  void _toggleShift() => setState(() => _shift = !_shift);

  void _confirm() {
    widget.onConfirm(_buffer);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(children: [
        Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 10),
        Row(children: [
          const SizedBox(width: 48),
          Expanded(
            child: Text(widget.title, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.textSecondary)),
          ),
          TextButton(onPressed: _clear, child: const Text('Clear')),
        ]),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
          child: Text(
            _buffer.isEmpty ? ' ' : (widget.obscureText ? '•' * _buffer.length : _buffer),
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: SingleChildScrollView(
            child: PosKeyboardKeys(shift: _shift, onType: _type, onSpace: _space, onBackspace: _backspace, onToggleShift: _toggleShift),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(width: double.infinity, height: 48, child: FilledButton.icon(onPressed: _confirm, icon: const Icon(Icons.check), label: const Text('Done'))),
      ]),
    );
  }
}

/// The key-grid itself, extracted so `PosSearchSheet` can reuse the exact
/// same QWERTY layout pinned below a live results list, rather than this
/// widget's own "type then Done" flow.
class PosKeyboardKeys extends StatelessWidget {
  final bool shift;
  final ValueChanged<String> onType;
  final VoidCallback onSpace;
  final VoidCallback onBackspace;
  final VoidCallback onToggleShift;

  const PosKeyboardKeys({super.key, required this.shift, required this.onType, required this.onSpace, required this.onBackspace, required this.onToggleShift});

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      for (final row in _kKeyboardRows) ...[
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          for (final ch in row) Expanded(child: _Key(label: shift ? ch.toUpperCase() : ch, onTap: () => onType(ch))),
        ]),
        const SizedBox(height: 6),
      ],
      Row(children: [
        Expanded(flex: 2, child: _Key(label: '⇧', muted: true, highlighted: shift, onTap: onToggleShift)),
        Expanded(flex: 5, child: _Key(label: 'space', muted: true, onTap: onSpace)),
        Expanded(flex: 2, child: _Key(label: '⌫', muted: true, onTap: onBackspace)),
      ]),
    ]);
  }
}

class _Key extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool muted;
  final bool highlighted;
  const _Key({required this.label, required this.onTap, this.muted = false, this.highlighted = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(3),
      child: Material(
        color: highlighted ? AppColors.primary.withValues(alpha: 0.15) : AppColors.background,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            height: 46,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.border)),
            alignment: Alignment.center,
            child: Text(label, style: TextStyle(fontSize: muted ? 13 : 16, fontWeight: FontWeight.w600, color: highlighted ? AppColors.primary : AppColors.textPrimary)),
          ),
        ),
      ),
    );
  }
}

/// The touch-first replacement for a raw `TextField` used as a manual-entry
/// FALLBACK next to a scan-first search field. Renders as a tappable display
/// box (same visual language as `PosAmountField`); tapping opens
/// `PosKeyboard`. The field's own value only changes once Done is tapped.
class PosKeyboardField extends StatelessWidget {
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final VoidCallback? onConfirmedSubmit;
  final bool obscureText;

  const PosKeyboardField({super.key, required this.label, required this.value, required this.onChanged, this.onConfirmedSubmit, this.obscureText = false});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => PosKeyboard.show(
          context,
          title: label,
          initialValue: value,
          obscureText: obscureText,
          onConfirm: (v) {
            onChanged(v);
            onConfirmedSubmit?.call();
          },
        ),
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
          child: Row(children: [
            const Icon(Icons.keyboard_outlined, size: 18, color: AppColors.textSecondary),
            const SizedBox(width: 10),
            Expanded(child: Text(value.isEmpty ? label : (obscureText ? '•' * value.length : value), style: TextStyle(fontSize: 15, color: value.isEmpty ? AppColors.textSecondary : AppColors.textPrimary))),
          ]),
        ),
      ),
    );
  }
}
