import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../utils/app_number_format.dart';
import '../utils/responsive.dart';
import 'report_hierarchy_export.dart';
import 'report_repository.dart';

/// Tree-building (PlNode, buildHierarchyTrees) and the section/totals
/// shape (HierarchyReportSpec, hierarchySpecFor) live in
/// report_hierarchy_export.dart, shared with both PDF/Excel export paths
/// so the on-screen tree and the exported one can never disagree — this
/// file keeps only the widget-specific state-aware flatten (respects
/// live expand/collapse, which a static export has no concept of).
class _PlRenderItem {
  const _PlRenderItem(this.node, this.depth);
  final PlNode node;
  final int depth; // 0 = section header itself
}

/// Renders a HIERARCHICAL report — first real build of this report_type
/// (see report_models.dart's ReportDefinition.isHierarchical, previously
/// checked nowhere in the app). Generic over any number of top-level
/// sections (Profit & Loss's Income/Expense; Balance Sheet's
/// Asset/Liability/Equity) via [reportKey] → hierarchySpecFor() — each a
/// genuine arbitrary-depth tree built from rows already fully loaded by
/// ReportDataController._loadAllForHierarchical, no pagination, no
/// per-node fetch, matching how small this kind of account tree
/// realistically is (never the huge row counts a detail feed like
/// Ageing/Pending Bills can hit).
class SakalReportHierarchicalTable extends StatefulWidget {
  final String reportKey;
  final List<ReportRow> rows;
  final ReportRow? totals;
  final String numberFormat;

  const SakalReportHierarchicalTable({
    super.key,
    required this.reportKey,
    required this.rows,
    required this.totals,
    required this.numberFormat,
  });

  @override
  State<SakalReportHierarchicalTable> createState() => _SakalReportHierarchicalTableState();
}

class _SakalReportHierarchicalTableState extends State<SakalReportHierarchicalTable> {
  late HierarchyReportSpec _spec;
  late Map<String, List<PlNode>> _treesBySection;
  final Map<String, bool> _sectionExpanded = {};

  @override
  void initState() {
    super.initState();
    _spec = hierarchySpecFor(widget.reportKey);
    for (final s in _spec.sections) {
      _sectionExpanded[s.key] = true;
    }
    _buildTrees();
  }

  @override
  void didUpdateWidget(covariant SakalReportHierarchicalTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.rows, widget.rows)) {
      _buildTrees();
    }
  }

  void _buildTrees() {
    _treesBySection = buildHierarchyTrees(widget.rows, _spec.sections);
  }

  List<_PlRenderItem> _flatten(HierarchySectionSpec section, num sectionTotal) {
    final items = <_PlRenderItem>[
      _PlRenderItem(PlNode(id: '__section__', name: section.label, levelDepth: 0, isLeaf: false, amount: sectionTotal), 0),
    ];
    if (_sectionExpanded[section.key] != true) {
      return items;
    }
    void walk(List<PlNode> nodes, int depth) {
      for (final n in nodes) {
        items.add(_PlRenderItem(n, depth));
        if (n.expanded) {
          walk(n.children, depth + 1);
        }
      }
    }

    walk(_treesBySection[section.key] ?? const [], 1);
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.totals;

    final items = <_PlRenderItem>[];
    for (final section in _spec.sections) {
      final sectionTotal = (t?[section.totalsKey] as num?) ?? 0;
      items.addAll(_flatten(section, sectionTotal));
    }

    return Column(children: [
      Expanded(
        child: ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, i) {
            final item = items[i];
            if (item.node.id == '__section__') {
              final section = _spec.sections.firstWhere((s) => s.label == item.node.name);
              return _sectionHeaderRow(
                section.label,
                item.node.amount,
                _sectionExpanded[section.key] == true,
                () => setState(() => _sectionExpanded[section.key] = !(_sectionExpanded[section.key] ?? true)),
              );
            }
            return _nodeRow(item.node, item.depth);
          },
        ),
      ),
      const Divider(height: 1, color: AppColors.border),
      for (final row in _spec.totalRows) _totalsRow(row.label, (t?[row.totalsKey] as num?) ?? 0),
    ]);
  }

  Widget _sectionHeaderRow(String label, num amount, bool expanded, VoidCallback onTap) => InkWell(
        onTap: onTap,
        child: Container(
          color: AppColors.primary,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(children: [
            Icon(expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right, size: 18, color: Colors.white),
            const SizedBox(width: 6),
            Expanded(
              child: Text(label.toUpperCase(),
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13, letterSpacing: 0.4)),
            ),
            Text(AppNumberFormat.amount(amount, widget.numberFormat),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
          ]),
        ),
      );

  // Indent lives INSIDE the name cell's own Expanded content, never
  // prepended ahead of the whole row — a prior bug this session (grouped
  // TABULAR nesting) shifted trailing numeric columns out of alignment
  // by doing that; here the amount is a separate fixed-position trailing
  // widget unaffected by however much indent the name side carries,
  // avoiding that class of bug by construction.
  Widget _nodeRow(PlNode node, int depth) => InkWell(
        onTap: node.isLeaf ? null : () => setState(() => node.expanded = !node.expanded),
        child: Container(
          decoration: BoxDecoration(
            color: node.isLeaf ? null : AppColors.surfaceVariant,
            border: const Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            Expanded(
              child: Row(children: [
                SizedBox(width: depth * 18.0),
                if (!node.isLeaf)
                  Icon(node.expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right, size: 16, color: AppColors.primary)
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(node.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, fontWeight: node.isLeaf ? FontWeight.w400 : FontWeight.w700)),
                ),
              ]),
            ),
            Text(AppNumberFormat.amount(node.amount, widget.numberFormat),
                style: TextStyle(fontSize: 13, fontWeight: node.isLeaf ? FontWeight.w400 : FontWeight.w700)),
          ]),
        ),
      );

  Widget _totalsRow(String label, num amount) => Container(
        color: AppColors.primaryLight.withValues(alpha: 0.12),
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: Responsive.isMobile(context) ? 8 : 10),
        child: Row(children: [
          Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14))),
          Text(AppNumberFormat.amount(amount, widget.numberFormat),
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
        ]),
      );
}
