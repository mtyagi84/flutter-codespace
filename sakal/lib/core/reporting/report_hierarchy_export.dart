import 'report_repository.dart';

/// One node in a real arbitrary-depth account tree — built once from the
/// flat rows a HIERARCHICAL report's own source function returns
/// (node_id, parent_id, section, node_name, level_depth, is_leaf, amount,
/// sort_key). Shared by the on-screen widget (SakalReportHierarchicalTable)
/// and both export paths (report_pdf_export.dart, report_excel_export.dart)
/// — same "one shared derivation, consumed everywhere, so none of them can
/// disagree" precedent report_matrix_pivot.dart already established for
/// MATRIX reports. Generic across every HIERARCHICAL report (Profit &
/// Loss's Income/Expense, Balance Sheet's Asset/Liability/Equity) — see
/// HierarchyReportSpec below for what varies per report family.
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

/// One top-level section a HIERARCHICAL report groups its tree into
/// (e.g. Income/Expense for P&L, Asset/Liability/Equity for Balance
/// Sheet). [key] matches the 'section' column value the SQL source
/// function returns; [totalsKey] looks up this section's own rolled-up
/// total in the report's totals object (fn_..._totals_base/_local).
class HierarchySectionSpec {
  const HierarchySectionSpec({required this.key, required this.label, required this.totalsKey});
  final String key;
  final String label;
  final String totalsKey;
}

/// One row of the trailing totals block (P&L: just "Net Profit";
/// Balance Sheet: "Total Assets" / "Total Liabilities & Equity" /
/// "Difference" — the report's own built-in correctness check, always 0
/// when classification and the Current Year Earnings figure are both
/// right). [totalsKey] looks up the figure in the same totals object.
class HierarchyTotalRowSpec {
  const HierarchyTotalRowSpec({required this.label, required this.totalsKey});
  final String label;
  final String totalsKey;
}

class HierarchyReportSpec {
  const HierarchyReportSpec({required this.sections, required this.totalRows});
  final List<HierarchySectionSpec> sections;
  final List<HierarchyTotalRowSpec> totalRows;
}

const _plSpec = HierarchyReportSpec(
  sections: [
    HierarchySectionSpec(key: 'INCOME', label: 'Income', totalsKey: 'income_total'),
    HierarchySectionSpec(key: 'EXPENSE', label: 'Expense', totalsKey: 'expense_total'),
  ],
  totalRows: [
    HierarchyTotalRowSpec(label: 'Net Profit', totalsKey: 'net_profit'),
  ],
);

const _balanceSheetSpec = HierarchyReportSpec(
  sections: [
    HierarchySectionSpec(key: 'ASSET', label: 'Assets', totalsKey: 'total_assets'),
    HierarchySectionSpec(key: 'LIABILITY', label: 'Liabilities', totalsKey: 'total_liabilities'),
    HierarchySectionSpec(key: 'EQUITY', label: 'Equity', totalsKey: 'total_equity'),
  ],
  totalRows: [
    HierarchyTotalRowSpec(label: 'Total Assets', totalsKey: 'total_assets'),
    HierarchyTotalRowSpec(label: 'Total Liabilities & Equity', totalsKey: 'total_liabilities_equity'),
    HierarchyTotalRowSpec(label: 'Difference', totalsKey: 'difference'),
  ],
);

/// The one place that knows which section/totals shape a given
/// HIERARCHICAL report family uses — everything else in this file, the
/// on-screen widget, and both exporters are fully generic over
/// [HierarchyReportSpec] and never hardcode a report_key. Matched by
/// prefix so PROFIT_LOSS_SUMMARY and PROFIT_LOSS_DETAIL (and similarly
/// both Balance Sheet reports) share one spec without repeating it.
/// Falls back to the P&L shape for any report_key it doesn't recognize —
/// should never actually happen for a real HIERARCHICAL report, but a
/// safe, non-crashing default beats an unhandled-case error.
HierarchyReportSpec hierarchySpecFor(String reportKey) {
  if (reportKey.startsWith('BALANCE_SHEET')) return _balanceSheetSpec;
  return _plSpec;
}

/// Builds one tree per section from the flat rows — each row's own
/// parent_id links it to its parent; a row whose parent_id doesn't
/// appear anywhere in this section's own node map is a level_depth==1
/// root (its true parent is the section's own synthetic root, which is
/// never itself a row — see migration 143's fn_pl_tree_base and its
/// Balance Sheet counterpart).
Map<String, List<PlNode>> buildHierarchyTrees(List<ReportRow> rows, List<HierarchySectionSpec> sections) {
  final bySection = <String, List<ReportRow>>{};
  for (final r in rows) {
    bySection.putIfAbsent('${r['section']}', () => []).add(r);
  }
  return {
    for (final s in sections) s.key: _buildSectionTree(bySection[s.key] ?? const []),
  };
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
  final bool isTotalRow; // the trailing totals block (see HierarchyReportSpec.totalRows)
}

/// Full-depth flatten for export — always fully expanded (a static
/// document has no concept of "collapsed"), unlike the on-screen
/// widget's own state-aware flatten. Every section in [spec.sections]
/// order (fully expanded), then every row in [spec.totalRows] order —
/// same figures as the on-screen footer, sourced from the same totals
/// object, never re-derived.
List<PlExportRow> flattenPlForExport({required List<ReportRow> rows, required ReportRow? totals, required HierarchyReportSpec spec}) {
  final trees = buildHierarchyTrees(rows, spec.sections);
  final out = <PlExportRow>[];

  void walk(List<PlNode> nodes, int depth) {
    for (final n in nodes) {
      out.add(PlExportRow(label: n.name, depth: depth, isGroup: !n.isLeaf, amount: n.amount));
      walk(n.children, depth + 1);
    }
  }

  for (final section in spec.sections) {
    final sectionTotal = (totals?[section.totalsKey] as num?) ?? 0;
    out.add(PlExportRow(label: section.label.toUpperCase(), depth: 0, isGroup: true, amount: sectionTotal));
    walk(trees[section.key] ?? const [], 1);
  }
  for (final row in spec.totalRows) {
    final amount = (totals?[row.totalsKey] as num?) ?? 0;
    out.add(PlExportRow(label: row.label, depth: 0, isGroup: true, amount: amount, isTotalRow: true));
  }
  return out;
}
