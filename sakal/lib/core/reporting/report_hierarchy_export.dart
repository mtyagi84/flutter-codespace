import 'report_repository.dart';

/// One node in a P&L's real arbitrary-depth account tree — built once
/// from the flat rows fn_pl_tree_*_base/_local returns (node_id,
/// parent_id, section, node_name, level_depth, is_leaf, amount,
/// sort_key). Shared by the on-screen widget (SakalReportHierarchicalTable)
/// and both export paths (report_pdf_export.dart, report_excel_export.dart)
/// — same "one shared derivation, consumed everywhere, so none of them can
/// disagree" precedent report_matrix_pivot.dart already established for
/// MATRIX reports.
class PlNode {
  PlNode({required this.id, required this.name, required this.levelDepth, required this.isLeaf, required this.amount});
  final String id;
  final String name;
  final int levelDepth;
  final bool isLeaf;
  final num amount;
  final List<PlNode> children = [];
  bool expanded = true; // widget-only UI state; export always walks full depth regardless
}

class PlSections {
  const PlSections({required this.incomeRoots, required this.expenseRoots});
  final List<PlNode> incomeRoots;
  final List<PlNode> expenseRoots;
}

/// Builds two independent trees (Income, Expense) from the flat rows —
/// each row's own parent_id links it to its parent; a row whose
/// parent_id doesn't appear anywhere in this section's own node map is a
/// level_depth==1 root (its true parent is the section's own synthetic
/// root, which is never itself a row — see migration 143's fn_pl_tree_base).
PlSections buildPlSections(List<ReportRow> rows) {
  final bySection = <String, List<ReportRow>>{};
  for (final r in rows) {
    bySection.putIfAbsent('${r['section']}', () => []).add(r);
  }
  return PlSections(
    incomeRoots: _buildSectionTree(bySection['INCOME'] ?? const []),
    expenseRoots: _buildSectionTree(bySection['EXPENSE'] ?? const []),
  );
}

List<PlNode> _buildSectionTree(List<ReportRow> rows) {
  final nodes = <String, PlNode>{};
  for (final r in rows) {
    final id = '${r['node_id']}';
    nodes[id] = PlNode(
      id: id,
      name: '${r['node_name']}',
      levelDepth: (r['level_depth'] as num).toInt(),
      isLeaf: r['is_leaf'] == true,
      amount: (r['amount'] as num?) ?? 0,
    );
  }
  final roots = <PlNode>[];
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
  int cmp(PlNode a, PlNode b) => a.name.compareTo(b.name);
  void sortRec(List<PlNode> list) {
    list.sort(cmp);
    for (final n in list) {
      sortRec(n.children);
    }
  }

  sortRec(roots);
  return roots;
}

/// One row of the export's flat, depth-indented representation.
class PlExportRow {
  const PlExportRow({required this.label, required this.depth, required this.isGroup, required this.amount, this.isTotalRow = false});
  final String label;
  final int depth; // 0 = section header / total row
  final bool isGroup; // bold in both PDF and Excel — section headers and group nodes
  final num amount;
  final bool isTotalRow; // the 3 trailing Income/Expense/Net Profit rows
}

/// Full-depth flatten for export — always fully expanded (a static
/// document has no concept of "collapsed"), unlike the on-screen
/// widget's own state-aware flatten. Income section (fully expanded)
/// then Expense section (fully expanded), then Total Income / Total
/// Expense / Net Profit — same order and figures as the on-screen
/// footer, sourced from the same totals object (fn_pl_totals_base/_local),
/// never re-derived.
List<PlExportRow> flattenPlForExport({required List<ReportRow> rows, required ReportRow? totals}) {
  final sections = buildPlSections(rows);
  final incomeTotal = (totals?['income_total'] as num?) ?? 0;
  final expenseTotal = (totals?['expense_total'] as num?) ?? 0;
  final netProfit = (totals?['net_profit'] as num?) ?? (incomeTotal - expenseTotal);

  final out = <PlExportRow>[];

  void walk(List<PlNode> nodes, int depth) {
    for (final n in nodes) {
      out.add(PlExportRow(label: n.name, depth: depth, isGroup: !n.isLeaf, amount: n.amount));
      walk(n.children, depth + 1);
    }
  }

  out.add(PlExportRow(label: 'INCOME', depth: 0, isGroup: true, amount: incomeTotal));
  walk(sections.incomeRoots, 1);
  out.add(PlExportRow(label: 'EXPENSE', depth: 0, isGroup: true, amount: expenseTotal));
  walk(sections.expenseRoots, 1);
  out.add(PlExportRow(label: 'Total Income', depth: 0, isGroup: true, amount: incomeTotal, isTotalRow: true));
  out.add(PlExportRow(label: 'Total Expense', depth: 0, isGroup: true, amount: expenseTotal, isTotalRow: true));
  out.add(PlExportRow(label: 'Net Profit', depth: 0, isGroup: true, amount: netProfit, isTotalRow: true));
  return out;
}
