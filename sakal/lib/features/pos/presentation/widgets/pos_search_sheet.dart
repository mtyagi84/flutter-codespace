import 'dart:async';
import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import 'pos_keyboard.dart';

/// A full live-search experience with NO reliance on any OS keyboard: a
/// search display box, a scrollable results list that updates as the user
/// types, and the on-screen QWERTY pinned at the bottom the whole time (never
/// a "type then Done then search" round trip). Used wherever a cashier needs
/// to find something from a list by typing — Customer Picker, Held Sales
/// search — anywhere the old "tap a TextField and hope a keyboard appears"
/// pattern was the only option.
class PosSearchSheet<T> extends StatefulWidget {
  final String title;
  final String hintText;
  final Future<List<T>> Function(String query) onSearch;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final ValueChanged<T> onSelected;
  final bool searchOnEmpty;

  const PosSearchSheet({
    super.key,
    required this.title,
    required this.hintText,
    required this.onSearch,
    required this.itemBuilder,
    required this.onSelected,
    this.searchOnEmpty = true,
  });

  static Future<void> show<T>(
    BuildContext context, {
    required String title,
    required String hintText,
    required Future<List<T>> Function(String query) onSearch,
    required Widget Function(BuildContext context, T item) itemBuilder,
    required ValueChanged<T> onSelected,
    bool searchOnEmpty = true,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.of(sheetContext).size.height * 0.88,
        child: PosSearchSheet<T>(title: title, hintText: hintText, onSearch: onSearch, itemBuilder: itemBuilder, onSelected: onSelected, searchOnEmpty: searchOnEmpty),
      ),
    );
  }

  @override
  State<PosSearchSheet<T>> createState() => _PosSearchSheetState<T>();
}

class _PosSearchSheetState<T> extends State<PosSearchSheet<T>> {
  String _query = '';
  bool _shift = false;
  bool _loading = false;
  List<T> _results = [];
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    if (widget.searchOnEmpty) _runSearch('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onQueryChanged(String q) {
    setState(() => _query = q);
    _debounce?.cancel();
    if (q.isEmpty && !widget.searchOnEmpty) {
      setState(() => _results = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () => _runSearch(q));
  }

  Future<void> _runSearch(String q) async {
    setState(() => _loading = true);
    try {
      final results = await widget.onSearch(q);
      if (mounted) setState(() { _results = results; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _results = []; _loading = false; });
    }
  }

  void _type(String ch) => _onQueryChanged(_query + (_shift ? ch.toUpperCase() : ch));
  void _space() => _onQueryChanged('$_query ');
  void _backspace() {
    if (_query.isEmpty) return;
    _onQueryChanged(_query.substring(0, _query.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(children: [
        Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 14),
        Row(children: [
          const SizedBox(width: 48),
          Expanded(
            child: Text(widget.title, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.textSecondary)),
          ),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ]),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
          child: Text(_query.isEmpty ? widget.hintText : _query, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: _query.isEmpty ? AppColors.textSecondary : AppColors.textPrimary)),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : _results.isEmpty
                  ? const Center(child: Text('No results.', style: TextStyle(color: AppColors.textSecondary)))
                  : ListView.builder(
                      itemCount: _results.length,
                      itemBuilder: (context, i) {
                        final item = _results[i];
                        return InkWell(
                          onTap: () {
                            widget.onSelected(item);
                            Navigator.of(context).pop();
                          },
                          child: widget.itemBuilder(context, item),
                        );
                      },
                    ),
        ),
        const SizedBox(height: 10),
        PosKeyboardKeys(shift: _shift, onType: _type, onSpace: _space, onBackspace: _backspace, onToggleShift: () => setState(() => _shift = !_shift)),
      ]),
    );
  }
}
