import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';

/// Shared searchable-picker field (product/customer/account/etc.) built on
/// [RawAutocomplete], adding Up/Down-arrow highlight navigation and
/// Enter-to-select — support Flutter's own [Autocomplete] never provides.
/// Every screen in this app used to hand-roll its own `Autocomplete<T>` +
/// near-identical inline `optionsViewBuilder`, none of them keyboard
/// navigable (confirmed: zero uses of `RawKeyboardListener`/`KeyboardListener`/
/// `Shortcuts`/arrow-key handling anywhere in the app before this widget).
/// New pickers should use this widget; existing ones migrate over time.
class SakalAutocomplete<T extends Object> extends StatefulWidget {
  final TextEditingValue? initialValue;
  final String Function(T option) displayStringForOption;
  final AutocompleteOptionsBuilder<T> optionsBuilder;
  final void Function(T selection) onSelected;
  final InputDecoration decoration;
  final bool enabled;
  final TextStyle? style;
  final FocusNode? focusNode;
  final double optionsMaxHeight;
  final double optionsMinWidth;

  /// Custom row content. Defaults to a plain [Text] of
  /// [displayStringForOption] — pass this for a subtitle row (e.g. the
  /// Account Picker convention: parent group shown under the account name).
  final Widget Function(BuildContext context, T option, bool isHighlighted)? optionBuilder;

  const SakalAutocomplete({
    super.key,
    this.initialValue,
    required this.displayStringForOption,
    required this.optionsBuilder,
    required this.onSelected,
    required this.decoration,
    this.enabled = true,
    this.style,
    this.focusNode,
    this.optionsMaxHeight = 260,
    this.optionsMinWidth = 280,
    this.optionBuilder,
  });

  @override
  State<SakalAutocomplete<T>> createState() => _SakalAutocompleteState<T>();
}

class _SakalAutocompleteState<T extends Object> extends State<SakalAutocomplete<T>> {
  final ValueNotifier<int> _highlighted = ValueNotifier(-1);
  int _optionsCount = 0;
  void Function(int index)? _selectHighlighted;

  // RawAutocomplete asserts focusNode and textEditingController are
  // supplied TOGETHER or not at all ("(focusNode == null) == (textEditingController
  // == null)") — a caller wanting an external focusNode (e.g. to
  // programmatically focus a newly-added line's Product field) would
  // otherwise trip that assert the moment this widget builds. Owning both
  // internally sidesteps it entirely: always paired, regardless of
  // whether the caller supplied a focusNode of its own.
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  late final bool _ownsFocusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue?.text ?? '');
    _ownsFocusNode = widget.focusNode == null;
    _focusNode = widget.focusNode ?? FocusNode();
  }

  @override
  void dispose() {
    _highlighted.dispose();
    _controller.dispose();
    if (_ownsFocusNode) _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_optionsCount == 0) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _highlighted.value = (_highlighted.value + 1) % _optionsCount;
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _highlighted.value = (_highlighted.value - 1 + _optionsCount) % _optionsCount;
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final idx = _highlighted.value;
      if (idx >= 0 && idx < _optionsCount) {
        _selectHighlighted?.call(idx);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<T>(
      textEditingController: _controller,
      focusNode: _focusNode,
      displayStringForOption: widget.displayStringForOption,
      optionsBuilder: widget.optionsBuilder,
      onSelected: (selection) {
        _highlighted.value = -1;
        widget.onSelected(selection);
      },
      fieldViewBuilder: (context, textEditingController, focusNode, onFieldSubmitted) => Focus(
        onKeyEvent: _onKey,
        child: TextFormField(
          controller: textEditingController,
          focusNode: focusNode,
          enabled: widget.enabled,
          style: widget.style,
          decoration: widget.decoration,
        ),
      ),
      optionsViewBuilder: (context, onSelected, options) {
        final optionsList = options.toList();
        _optionsCount = optionsList.length;
        _selectHighlighted = (i) => onSelected(optionsList[i]);
        // A fresh options list always starts with the first item
        // highlighted (not unhighlighted) — lets a fast typist hit Enter
        // immediately after typing without an extra Down-arrow press,
        // matching familiar search-box UX.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _highlighted.value = optionsList.isEmpty ? -1 : 0;
        });
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(4),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: widget.optionsMaxHeight, minWidth: widget.optionsMinWidth),
              child: ValueListenableBuilder<int>(
                valueListenable: _highlighted,
                builder: (context, highlightedIndex, _) => ListView.builder(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  itemCount: optionsList.length,
                  itemBuilder: (context, idx) {
                    final option = optionsList[idx];
                    final isHighlighted = idx == highlightedIndex;
                    return InkWell(
                      onTap: () => onSelected(option),
                      child: Container(
                        color: isHighlighted ? AppColors.primary.withValues(alpha: 0.08) : null,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: widget.optionBuilder?.call(context, option, isHighlighted) ??
                            Text(widget.displayStringForOption(option), style: const TextStyle(fontSize: 13)),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
