import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../utils/app_number_format.dart';
import '../utils/responsive.dart';
import 'report_repository.dart';

/// One node in a P&L's real arbitrary-depth account tree — built once,
/// client-side, from the single flat fetch fn_pl_tree_*_base/_local
/// returns (node_id, parent_id, section, node_name, level_depth,
/// is_leaf, amount, sort_key). Unlike the grouped-TABULAR mechanism's
/// ReportGroupNode, nothing here is lazy — the whole tree is already in
/// memory, so expand/collapse is pure local UI state, no controller
/// round-trip. See sakal_report_table.dart's own _flattenGroups for the
/// precedent this mirrors (flatten a tree into one ListView.builder-
/// friendly list, indent by depth).
class _PlNode {
  _PlNode({required this.id, required this.name, required this.levelDepth, required this.isLeaf, required this.amount});
  final String id;
  final String name;
  final int levelDepth;
  final bool isLeaf;
  final num amount;
  final List<_PlNode> children = [];
  bool expanded = true; // P&L trees are small — default open, unlike Ageing/Pending Bills' default-collapsed currency groups
}

class _PlRenderItem {
  const _PlRenderItem(this.node, this.depth);
  final _PlNode node;
  final int depth; // 0 = section header itself
}

/// Renders a HIERARCHICAL report — first real build of this report_type
/// (see report_models.dart's ReportDefinition.isHierarchical, previously
/// checked nowhere in the app). Two top-level sections (Income, Expense),
/// each a genuine arbitrary-depth tree built from rows already fully
/// loaded by ReportDataController._loadAllForHierarchical — no
/// pagination, no per-node fetch, matching how small a P&L's own account
/// tree realistically is (never the huge row counts a detail feed like
/// Ageing/Pending Bills can hit).
class SakalReportHierarchicalTable extends StatefulWidget {
  final List<ReportRow> rows;
  final ReportRow? totals; // {income_total, expense_total, net_profit}
  final String numberFormat;

  const SakalReportHierarchicalTable({super.key, required this.rows, required this.totals, required this.numberFormat});

  @override
  State<SakalReportHierarchicalTable> createState() => _SakalReportHierarchicalTableState();
}

class _SakalReportHierarchicalTableState extends State<SakalReportHierarchicalTable> {
  late List<_PlNode> _incomeRoots;
  late List<_PlNode> _expenseRoots;

  @override
  void initState() {
    super.initState();
    _buildTrees();
  }

  @override
  void didUpdateWidget(covariant SakalReportHierarchicalTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.rows, widget.rows)) {
      _buildTrees();
    }
  }

  // rows arrive flat, each carrying its own parent_id — link them into a
  // real tree per section. A row whose parent_id doesn't appear anywhere
  // in this section's own node map is a level_depth==1 root (its true
  // parent is the section's own synthetic root, which is never itself a
  // row — see migration 143's fn_pl_tree_base).
  void _buildTrees() {
    final bySection = <String, List<ReportRow>>{};
    for (final r in widget.rows) {
      bySection.putIfAbsent('${r['section']}', () => []).add(r);
    }
    _incomeRoots = _buildSectionTree(bySection['INCOME'] ?? const []);
    _expenseRoots = _buildSectionTree(bySection['EXPENSE'] ?? const []);
  }

  List<_PlNode> _buildSectionTree(List<ReportRow> rows) {
    final nodes = <String, _PlNode>{};
    for (final r in rows) {
      final id = '${r['node_id']}';
      nodes[id] = _PlNode(
        id: id,
        name: '${r['node_name']}',
        levelDepth: (r['level_depth'] as num).toInt(),
        isLeaf: r['is_leaf'] == true,
        amount: (r['amount'] as num?) ?? 0,
      );
    }
    final roots = <_PlNode>[];
    for (final r in rows) {
      final id = '${r['node_id']}';
      final parentId = r['parent_id']?.toString();
      final node = nodes[id]!;
      final parent = parentId != null ? nodes[parentId] : null;
      if (parent != null) {
        parent.children.add(node);
      } else {
        roots.add(node);
      }
    }
    int cmp(_PlNode a, _PlNode b) => a.name.compareTo(b.name);
    void sortRec(List<_PlNode> list) {
      list.sort(cmp);
      for (final n in list) {
        sortRec(n.children);
      }
    }

    sortRec(roots);
    return roots;
  }

  List<_PlRenderItem> _flatten(String sectionLabel, num sectionTotal, List<_PlNode> roots, bool sectionExpanded) {
    final items = <_PlRenderItem>[
      _PlRenderItem(_PlNode(id: '__section__', name: sectionLabel, levelDepth: 0, isLeaf: false, amount: sectionTotal), 0),
    ];
    if (!sectionExpanded) {
      return items;
    }
    void walk(List<_PlNode> nodes, int depth) {
      for (final n in nodes) {
        items.add(_PlRenderItem(n, depth));
        if (n.expanded) {
          walk(n.children, depth + 1);
        }
      }
    }

    walk(roots, 1);
    return items;
  }

  bool _incomeSectionExpanded = true;
  bool _expenseSectionExpanded = true;

  @override
  Widget build(BuildContext context) {
    final t = widget.totals;
    final incomeTotal = (t?['income_total'] as num?) ?? 0;
    final expenseTotal = (t?['expense_total'] as num?) ?? 0;
    final netProfit = (t?['net_profit'] as num?) ?? (incomeTotal - expenseTotal);

    final items = [
      ..._flatten('Income', incomeTotal, _incomeRoots, _incomeSectionExpanded),
      ..._flatten('Expense', expenseTotal, _expenseRoots, _expenseSectionExpanded),
    ];

    return Column(children: [
      Expanded(
        child: ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, i) {
            final item = items[i];
            if (item.node.id == '__section__') {
              final isIncome = item.node.name == 'Income';
              return _sectionHeaderRow(
                item.node.name,
                item.node.amount,
                isIncome ? _incomeSectionExpanded : _expenseSectionExpanded,
                isIncome ? () => setState(() => _incomeSectionExpanded = !_incomeSectionExpanded) : () => setState(() => _expenseSectionExpanded = !_expenseSectionExpanded),
              );
            }
            return _nodeRow(item.node, item.depth);
          },
        ),
      ),
      const Divider(height: 1, color: AppColors.border),
      _totalsRow('Net Profit', netProfit),
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
  Widget _nodeRow(_PlNode node, int depth) => InkWell(
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
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: Responsive.isMobile(context) ? 10 : 12),
        child: Row(children: [
          Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14))),
          Text(AppNumberFormat.amount(amount, widget.numberFormat),
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
        ]),
      );
}
