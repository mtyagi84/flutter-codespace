import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../utils/responsive.dart';

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

  /// Fires on every keystroke, same as a plain [TextField.onChanged].
  /// Needed for a "clear the field to reset the selection" pattern (e.g. a
  /// category/parent filter where an empty field means "no filter") — a
  /// raw [Autocomplete]'s own [onChanged] normally does this, and callers
  /// migrating onto this widget lose that unless it's exposed here too.
  final ValueChanged<String>? onChanged;

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
    this.onChanged,
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

  Future<void> _openMobilePicker(BuildContext context) async {
    final selection = await showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _MobileAutocompleteSheet<T>(
        title: widget.decoration.labelText ?? widget.decoration.hintText ?? 'Option',
        initialQuery: _controller.text,
        optionsBuilder: widget.optionsBuilder,
        displayStringForOption: widget.displayStringForOption,
        optionBuilder: widget.optionBuilder,
      ),
    );

    if (selection != null) {
      _controller.text = widget.displayStringForOption(selection);
      widget.onSelected(selection);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = Responsive.isMobile(context);

    if (isMobile) {
      return InkWell(
        onTap: widget.enabled ? () => _openMobilePicker(context) : null,
        child: IgnorePointer(
          child: TextFormField(
            controller: _controller,
            enabled: widget.enabled,
            style: widget.style,
            decoration: widget.decoration.copyWith(
              suffixIcon: const Icon(Icons.arrow_drop_down, size: 20, color: AppColors.primary),
            ),
            onChanged: widget.onChanged,
          ),
        ),
      );
    }

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
          onChanged: widget.onChanged,
        ),
      ),
      optionsViewBuilder: (context, onSelected, options) {
        final optionsList = options.toList();
        _optionsCount = optionsList.length;
        _selectHighlighted = (i) => onSelected(optionsList[i]);
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

class _MobileAutocompleteSheet<T extends Object> extends StatefulWidget {
  final String title;
  final String initialQuery;
  final AutocompleteOptionsBuilder<T> optionsBuilder;
  final String Function(T option) displayStringForOption;
  final Widget Function(BuildContext context, T option, bool isHighlighted)? optionBuilder;

  const _MobileAutocompleteSheet({
    required this.title,
    required this.initialQuery,
    required this.optionsBuilder,
    required this.displayStringForOption,
    this.optionBuilder,
  });

  @override
  State<_MobileAutocompleteSheet<T>> createState() => _MobileAutocompleteSheetState<T>();
}

class _MobileAutocompleteSheetState<T extends Object> extends State<_MobileAutocompleteSheet<T>> {
  late final TextEditingController _searchCtrl;
  List<T> _filtered = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController(text: widget.initialQuery);
    _runSearch(widget.initialQuery);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _runSearch(String query) async {
    setState(() => _loading = true);
    final results = await widget.optionsBuilder(TextEditingValue(text: query));
    if (mounted) {
      setState(() {
        _filtered = results.toList();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      padding: EdgeInsets.only(bottom: bottomInset),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Container(width: 36, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Expanded(child: Text(widget.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.primary))),
                IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(context)),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchCtrl,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Search…',
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _searchCtrl.text.isNotEmpty
                    ? IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: () { _searchCtrl.clear(); _runSearch(''); })
                    : null,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onChanged: (v) => _runSearch(v),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _filtered.isEmpty
                    ? const Center(child: Text('No matching items found', style: TextStyle(color: AppColors.textSecondary)))
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: _filtered.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, indent: 16, endIndent: 16),
                        itemBuilder: (context, idx) {
                          final option = _filtered[idx];
                          return InkWell(
                            onTap: () => Navigator.pop(context, option),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                              child: widget.optionBuilder?.call(context, option, false) ??
                                  Text(widget.displayStringForOption(option), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
