import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/sakal_autocomplete.dart';
import '../../../../core/widgets/sakal_field_card.dart';

/// Finance-specific account picker — shows Account Code, Account Name,
/// and Parent Group as three genuinely separate, aligned columns, not
/// the `[code] name` + small grey parent-subtitle convention used by
/// Sales/Purchase account pickers elsewhere in the app. Scoped to
/// Finance screens only (Journal Voucher first; Payment/Receipt Voucher
/// is a flagged follow-up, not retrofitted by this file's existence).
///
/// Two accounts can legitimately share the same name under different
/// parent groups (e.g. "Rent" under Expense vs. "Rent" under
/// Provisions) — the old subtitle hint is too subtle to disambiguate
/// quickly; three visible columns fixes that.
///
/// [accounts] is the already-fetched, already-cached full list (from
/// `accountsProvider`) — this widget does no fetching of its own, it's
/// a pure picker over whatever list the caller supplies (letting a
/// caller apply its own nature exclusion, e.g. Journal Voucher
/// excluding Cash/Bank, before ever reaching this widget).
class FinanceAccountPicker extends StatelessWidget {
  final List<Map<String, dynamic>> accounts;
  final String? initialValue;
  final bool enabled;
  final ValueChanged<Map<String, dynamic>> onSelected;
  final FocusNode? focusNode;
  final InputDecoration? decoration;
  final TextStyle? style;

  const FinanceAccountPicker({
    super.key,
    required this.accounts,
    required this.onSelected,
    this.initialValue,
    this.enabled = true,
    this.focusNode,
    this.decoration,
    this.style,
  });

  static String _parentName(Map<String, dynamic> account) =>
      (account['parent'] as Map<String, dynamic>?)?['account_name'] as String? ?? '';

  static String displayString(Map<String, dynamic> account) =>
      '[${account['account_code']}] ${account['account_name']}';

  /// Searches Code, Name, AND Parent Group — all three, not just code/name.
  /// Feasible as a plain in-memory filter (not a PostgREST query concern)
  /// because [accounts] is already a fully-fetched, already-embedded list.
  static bool matchesSearch(Map<String, dynamic> account, String query) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    final code = (account['account_code'] as String? ?? '').toLowerCase();
    final name = (account['account_name'] as String? ?? '').toLowerCase();
    final parent = _parentName(account).toLowerCase();
    return code.contains(q) || name.contains(q) || parent.contains(q);
  }

  Iterable<Map<String, dynamic>> _search(TextEditingValue textEditingValue) =>
      accounts.where((a) => matchesSearch(a, textEditingValue.text)).take(50);

  // Header labels and every optionRow share this exact column shape
  // (110px code / flex 2 name / flex 1 parent) so the header and rows stay
  // pixel-aligned — same convention as SakalTableHeaderBar + line-item rows
  // elsewhere in this app.
  static const double _codeColumnWidth = 110;

  static Widget _headerRow() {
    const style = TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: AppColors.textSecondary, letterSpacing: 0.4);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: AppColors.background,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: const Row(children: [
        SizedBox(width: _codeColumnWidth, child: Text('ACCOUNT CODE', style: style)),
        Expanded(flex: 2, child: Text('ACCOUNT NAME', style: style)),
        Expanded(flex: 1, child: Text('GROUP NAME', style: style)),
      ]),
    );
  }

  static Widget optionRow(Map<String, dynamic> account, {bool highlighted = false}) {
    final code = account['account_code'] as String? ?? '';
    final name = account['account_name'] as String? ?? '';
    final parent = _parentName(account);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: highlighted ? AppColors.primary.withValues(alpha: 0.08) : null,
        // Subtle row divider (no vertical column lines) — a deliberate,
        // user-confirmed choice over a literal full spreadsheet grid.
        border: const Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(children: [
        // Widened from a fixed 70px — this schema's hierarchical account
        // codes routinely run to 10-13+ digits (e.g. "1120001001001"),
        // which wrapped onto 2 lines at 70px and squeezed Name/Parent into
        // near-unreadable widths (found live 2026-08-15, Account Ledger's
        // own account filter). 110px + the wider optionsMinWidth below
        // give every column real room regardless of code length.
        SizedBox(width: _codeColumnWidth, child: Text(code, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
        Expanded(flex: 2, child: Text(name, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
        Expanded(flex: 1, child: Text(parent, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary), overflow: TextOverflow.ellipsis)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SakalAutocomplete<Map<String, dynamic>>(
      initialValue: initialValue != null ? TextEditingValue(text: initialValue!) : null,
      enabled: enabled,
      focusNode: focusNode,
      decoration: decoration ?? SakalFieldCard.bareDecoration,
      style: style,
      displayStringForOption: displayString,
      optionsBuilder: _search,
      onSelected: onSelected,
      optionBuilder: (context, option, isHighlighted) => optionRow(option, highlighted: isHighlighted),
      optionsHeader: _headerRow(),
      // A separate modal dialog (fixed 640px width, independent of the
      // field's own width) instead of the inline dropdown — user-requested
      // 2026-08-16 after the inline dropdown, even widened, still rendered
      // at roughly the anchor field's own narrow width in practice (a
      // RawAutocomplete follower-width quirk — see
      // SakalAutocomplete.desktopDialogMode's own doc comment). Mobile is
      // unaffected either way.
      desktopDialogMode: true,
    );
  }
}
