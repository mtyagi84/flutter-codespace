import 'package:flutter/widgets.dart';

/// Wires a barcode-entry `TextFormField`'s own `FocusNode` so that losing
/// focus via Tab ALSO triggers the same product-lookup callback Enter does
/// — not just Enter/`onFieldSubmitted`, which Flutter never calls for a
/// Tab-driven focus change (Tab is handled by the framework's own focus
/// traversal and bypasses `onFieldSubmitted`/`onEditingComplete` entirely
/// unless something explicitly listens for it, which nothing in this app
/// did before this controller existed). Also makes a resubmission of the
/// SAME, already-resolved barcode text a no-op — pressing Enter or Tab a
/// second time without changing the text does nothing, rather than
/// re-running the lookup (and, on screens where a match adds a new line,
/// silently adding a duplicate).
///
/// Usage — replace a raw field's own `onFieldSubmitted` with this:
/// ```dart
/// final scan = BarcodeScanFieldController(
///   focusNode: row.barcodeFocusNode,
///   controller: row.barcodeCtrl,
///   onSubmit: (value) => _onBarcodeSubmitted(row, value),
/// );
/// // ...
/// TextFormField(
///   controller: row.barcodeCtrl,
///   focusNode: row.barcodeFocusNode,
///   onFieldSubmitted: scan.handleFieldSubmitted,
/// )
/// // in dispose():
/// scan.dispose();
/// ```
/// A row model typically owns both the `FocusNode` and this controller as
/// plain fields (see `DeferredRowDisposal` for the disposal convention
/// already used elsewhere in this app for per-row `FocusNode`s) — this
/// class itself does not create or dispose the `FocusNode` it's given,
/// only listens to it.
class BarcodeScanFieldController {
  BarcodeScanFieldController({
    required this.focusNode,
    required this.controller,
    required this.onSubmit,
  }) {
    focusNode.addListener(_onFocusChange);
  }

  final FocusNode focusNode;
  final TextEditingController controller;
  final void Function(String value) onSubmit;

  String? _lastSubmitted;

  void _onFocusChange() {
    if (!focusNode.hasFocus) _trySubmit();
  }

  /// Pass directly as a `TextFormField`'s `onFieldSubmitted` — covers
  /// Enter (and any other IME "done" action) the same way it always did.
  void handleFieldSubmitted(String value) => _trySubmit();

  void _trySubmit() {
    final text = controller.text.trim();
    if (text.isEmpty) return;
    if (text == _lastSubmitted) return; // unchanged resubmission — no-op
    _lastSubmitted = text;
    onSubmit(text);
  }

  /// Must be called from the owning row/screen's own `dispose()` — removes
  /// the focus listener only; the `FocusNode` itself is owned and disposed
  /// by the caller, same convention as everywhere else in this app.
  void dispose() => focusNode.removeListener(_onFocusChange);
}
