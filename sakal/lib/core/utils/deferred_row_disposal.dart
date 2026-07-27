import 'package:flutter/widgets.dart';

/// Implemented by any per-row model class (a line/charge/bill row on an
/// entry screen) that owns disposable resources — a [TextEditingController],
/// a [FocusNode], or both.
abstract class DisposableRow {
  void dispose();
}

/// Fixes a recurring crash: disposing a row's FocusNode/controller
/// synchronously, inside the very `setState` that removes it from a live
/// list, can crash if that FocusNode still has focus or its controller is
/// still attached to a widget in the current frame. The safe, proven fix
/// (already hand-rolled per-screen in Sales Invoice, Cash Receipt, Journal
/// Voucher, and Expense Voucher before this mixin existed) is to never
/// dispose a removed row immediately — only when the screen itself closes.
///
/// Usage:
/// ```dart
/// class _MyRow implements DisposableRow {
///   final FocusNode node = FocusNode();
///   @override void dispose() => node.dispose();
/// }
///
/// class _MyScreenState extends ConsumerState<MyScreen>
///     with DeferredRowDisposal<MyScreen> {
///   void _removeLine(_MyRow row) {
///     setState(() => _lines.remove(row));
///     deferRowDisposal(row); // NOT row.dispose() here
///   }
///
///   @override
///   void dispose() {
///     for (final l in _lines) { l.dispose(); }
///     disposeDeferredRows();
///     super.dispose();
///   }
/// }
/// ```
mixin DeferredRowDisposal<T extends StatefulWidget> on State<T> {
  final List<DisposableRow> _pendingRowDisposal = [];

  /// Call instead of disposing a row removed from a live list immediately.
  void deferRowDisposal(DisposableRow row) => _pendingRowDisposal.add(row);

  /// Call from this State's own `dispose()`, alongside disposing whatever
  /// rows are still live in the list.
  @protected
  void disposeDeferredRows() {
    for (final row in _pendingRowDisposal) {
      row.dispose();
    }
    _pendingRowDisposal.clear();
  }
}
