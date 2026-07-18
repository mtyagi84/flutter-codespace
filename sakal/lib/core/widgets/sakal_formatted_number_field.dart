import 'package:flutter/material.dart';
import '../utils/app_number_format.dart';

/// A numeric entry field that shows a grouped, rounded display
/// ("34,362.17") once the user is done editing, but keeps the field's own
/// [controller] holding a PLAIN numeric string ("34362.165") at all times.
///
/// This split is deliberate, not incidental: `controller` is very often
/// the SAME `TextEditingController` a screen already runs
/// `double.tryParse(controller.text)` against in a dozen other places
/// (recompute totals, validate before save, build the save payload, ...).
/// Reformatting that shared controller's own text with commas would
/// silently break every one of those parse sites the moment a comma
/// slipped into a stored value — a financial field failing to parse
/// typically falls back to 0 via `?? 0`, which is a silent wrong-amount
/// bug, not a crash. Owning a SEPARATE internal display controller avoids
/// that risk entirely: [controller] is only ever written a stripped,
/// plain numeric string, exactly as if this widget didn't exist.
///
/// Formats on blur, not while typing — while focused the field shows the
/// same plain digits it always has (simplest to edit precisely, and the
/// same UX plenty of real-world financial software uses), and reformats
/// with grouping only once the user moves on. Live comma-insertion while
/// typing needs cursor-position-aware `TextInputFormatter` logic, a
/// separate and meaningfully riskier piece of work not attempted here.
class SakalFormattedNumberField extends StatefulWidget {
  final TextEditingController controller;
  final int decimalPlaces;
  final String numberFormatStyle;
  final bool enabled;
  final InputDecoration decoration;
  final TextStyle? style;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onFieldSubmitted;

  const SakalFormattedNumberField({
    super.key,
    required this.controller,
    required this.numberFormatStyle,
    this.decimalPlaces = 2,
    this.enabled = true,
    this.decoration = const InputDecoration(),
    this.style,
    this.focusNode,
    this.onChanged,
    this.onFieldSubmitted,
  });

  @override
  State<SakalFormattedNumberField> createState() => _SakalFormattedNumberFieldState();
}

class _SakalFormattedNumberFieldState extends State<SakalFormattedNumberField> {
  late final TextEditingController _displayCtrl;
  late final FocusNode _focusNode;
  late final bool _ownsFocusNode;

  // Re-entrancy guards — writing to one controller from the other's own
  // listener would otherwise recurse (display -> real -> display -> ...).
  bool _writingDisplay = false;
  bool _writingReal = false;

  @override
  void initState() {
    super.initState();
    _ownsFocusNode = widget.focusNode == null;
    _focusNode = widget.focusNode ?? FocusNode();
    _displayCtrl = TextEditingController(text: _formatted(widget.controller.text));
    widget.controller.addListener(_onRealChanged);
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onRealChanged);
    _focusNode.removeListener(_onFocusChanged);
    if (_ownsFocusNode) _focusNode.dispose();
    _displayCtrl.dispose();
    super.dispose();
  }

  String _formatted(String raw) {
    if (raw.trim().isEmpty) return '';
    final v = double.tryParse(raw);
    if (v == null) return raw;
    return AppNumberFormat.rate(v, decimalPlaces: widget.decimalPlaces, numberFormatStyle: widget.numberFormatStyle);
  }

  String _stripped(String text) => text.replaceAll(',', '');

  void _onRealChanged() {
    if (_writingReal) return;
    // A programmatic change to the underlying controller while the user
    // is actively editing (e.g. a price auto-resolve firing mid-type)
    // would yank their cursor if applied to the display now — defer to
    // the next focus-out instead.
    if (_focusNode.hasFocus) return;
    _writingDisplay = true;
    _displayCtrl.text = _formatted(widget.controller.text);
    _writingDisplay = false;
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus) {
      _writingDisplay = true;
      _displayCtrl.value = TextEditingValue(
        text: widget.controller.text,
        selection: TextSelection(baseOffset: 0, extentOffset: widget.controller.text.length),
      );
      _writingDisplay = false;
    } else {
      _writingDisplay = true;
      _displayCtrl.text = _formatted(widget.controller.text);
      _writingDisplay = false;
    }
  }

  void _onDisplayChanged(String text) {
    if (_writingDisplay) return;
    _writingReal = true;
    widget.controller.text = _stripped(text);
    _writingReal = false;
    widget.onChanged?.call(widget.controller.text);
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: _displayCtrl,
      focusNode: _focusNode,
      enabled: widget.enabled,
      style: widget.style,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: widget.decoration,
      onChanged: _onDisplayChanged,
      onFieldSubmitted: widget.onFieldSubmitted,
    );
  }
}
