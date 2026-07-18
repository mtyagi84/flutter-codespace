import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/app_colors.dart';
import '../theme/theme_presets.dart';

/// Shared dark-headed line-item card — the mobile counterpart of a
/// document's desktop line-items table (paired with
/// [SakalTableHeaderBar]). Renders a theme-preset-colored header (title +
/// optional subtitle + optional trailing actions/delete) over a body of
/// [fields] (typically [SakalFieldCard]s in a `Wrap`), with room for extra
/// content ([body] — e.g. a batch/serial allocation section) and a
/// [footer] (e.g. the line's computed amount).
///
/// Built generic on purpose: any document entry screen with product/item
/// lines (PO, GRN, Material Requisition, Stock Transfer, Sales
/// Order/Quotation, ...) can reuse this same shell for its own mobile line
/// cards rather than each hand-rolling a bordered `Container`.
class SakalLineItemCard extends ConsumerWidget {
  final String title;
  final String? subtitle;
  final List<Widget> fields;
  final Widget? body;
  final Widget? footer;
  final Widget? trailingHeaderAction;
  final VoidCallback? onDelete;

  const SakalLineItemCard({
    super.key,
    required this.title,
    this.subtitle,
    required this.fields,
    this.body,
    this.footer,
    this.trailingHeaderAction,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preset = ThemePresetConfig.all[ref.watch(themePresetProvider)]!;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          color: preset.primary,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
                if (subtitle != null)
                  Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 11)),
              ]),
            ),
            if (trailingHeaderAction != null) trailingHeaderAction!,
            if (onDelete != null)
              IconButton(
                icon: const Icon(Icons.close, size: 18, color: Colors.white),
                onPressed: onDelete,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                tooltip: 'Remove line',
              ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 10, runSpacing: 10, children: fields),
            if (body != null) ...[const SizedBox(height: 10), body!],
            if (footer != null) ...[const SizedBox(height: 8), footer!],
          ]),
        ),
      ]),
    );
  }
}
