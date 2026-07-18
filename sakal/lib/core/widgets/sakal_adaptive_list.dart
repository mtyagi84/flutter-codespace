import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/app_colors.dart';
import '../theme/theme_presets.dart';
import '../utils/responsive.dart';

/// Desktop-table header column spec for [SakalAdaptiveList].
class SakalListColumn {
  final String label;
  final int flex;
  const SakalListColumn(this.label, {this.flex = 1});
}

/// Shared mobile-card / desktop-table list body. Every list screen used to
/// hand-roll this exact loading/error/empty + isMobile switch — this widget
/// owns that shell so a screen only supplies its own column spec and one
/// row-to-card / one row-to-table-row builder. Generic over the row type `T`
/// since some screens keep rows as raw PostgREST maps and others as typed models.
///
/// Header styling rolled onto the confirmed redesign's dark/theme-reactive
/// look (matching [SakalTableHeaderBar]'s own header, used on entry
/// screens) — user-requested app-wide rollout, applied once here so all 14
/// screens sharing this widget pick it up for free, rather than each
/// screen hand-rolling its own header container.
class SakalAdaptiveList<T> extends ConsumerWidget {
  final bool loading;
  final String? error;
  final List<T> rows;
  final List<SakalListColumn> columns;
  final Widget Function(T row, int index) rowBuilder;
  final Widget Function(T row) cardBuilder;
  final Widget emptyState;

  const SakalAdaptiveList({
    super.key,
    required this.loading,
    required this.error,
    required this.rows,
    required this.columns,
    required this.rowBuilder,
    required this.cardBuilder,
    required this.emptyState,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) return Center(child: Text(error!, style: const TextStyle(color: AppColors.negative)));
    if (rows.isEmpty) return emptyState;

    if (Responsive.isMobile(context)) {
      return ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        itemCount: rows.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) => cardBuilder(rows[i]),
      );
    }

    final preset = ThemePresetConfig.all[ref.watch(themePresetProvider)]!;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
      child: Column(children: [
        Container(
          decoration: BoxDecoration(color: preset.primary, borderRadius: const BorderRadius.vertical(top: Radius.circular(9))),
          child: Row(children: columns.map((c) => _th(c.label, flex: c.flex)).toList()),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.border),
            itemBuilder: (_, i) => rowBuilder(rows[i], i),
          ),
        ),
      ]),
    );
  }

  static Widget _th(String label, {int flex = 1}) => Expanded(
    flex: flex,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      child: Text(
        label.toUpperCase(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 10.5, letterSpacing: 0.5),
      ),
    ),
  );
}
