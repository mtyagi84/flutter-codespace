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

  const FinanceAccountPicker({
    super.key,
    required this.accounts,
    required this.onSelected,
    this.initialValue,
    this.enabled = true,
    this.focusNode,
    this.decoration,
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

  static Widget optionRow(Map<String, dynamic> account, {bool highlighted = false}) {
    final code = account['account_code'] as String? ?? '';
    final name = account['account_name'] as String? ?? '';
    final parent = _parentName(account);
    return Container(
      color: highlighted ? AppColors.primary.withValues(alpha: 0.08) : null,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        SizedBox(width: 70, child: Text(code, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
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
      displayStringForOption: displayString,
      optionsBuilder: _search,
      onSelected: onSelected,
      optionsMinWidth: 380,
      optionBuilder: (context, option, isHighlighted) => optionRow(option, highlighted: isHighlighted),
    );
  }
}
