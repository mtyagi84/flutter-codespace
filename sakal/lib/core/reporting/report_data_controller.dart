import 'report_models.dart';
import 'report_repository.dart';

/// One row in a grouped report's expand/collapse tree — see
/// sakal/docs/reporting_engine_design.md's "Grouping & subtotals" section.
/// [ancestorKeys] is the filter to apply when fetching THIS node's own
/// children (its own key already folded in), so expanding a node never
/// needs to walk back up the tree.
class ReportGroupNode {
  ReportGroupNode({required this.summaryRow, required this.levelNo, required this.ancestorKeys});

  final ReportRow summaryRow;
  final int levelNo;
  final Map<String, String> ancestorKeys;

  bool expanded = false;
  bool loading = false;

  // Populated once expanded, exactly one of the two depending on whether
  // this node's level is the deepest configured grouping level.
  List<ReportGroupNode>? childGroups;
  List<ReportRow>? childDetailRows;
  int childDetailOffset = 0;
  bool childDetailHasMore = true;
  bool childDetailLoadingMore = false;
}

/// Owns all live state for one report screen: filters, sort, the
/// paginated detail list (ungrouped reports) OR the group tree (grouped
/// reports), and the report-level totals bar. Same "plain class, caller
/// wraps every call in try/catch + setState" convention as
/// PagedListController (see core/utils/paged_list_controller.dart) — this
/// class owns no error presentation or rebuild triggering of its own.
class ReportDataController {
  ReportDataController({required this.repository, required this.bundle});

  final ReportRepository repository;
  final ReportBundle bundle;

  String? sortColumn;
  String? sortDir; // ASC | DESC
  Map<String, dynamic> filterValues = {};

  bool isLoading = false;
  ReportRow? totals;

  // Ungrouped-report state
  List<ReportRow> items = [];
  bool isLoadingMore = false;
  bool hasMore = true;
  int? totalCount;
  int _offset = 0;

  // Grouped-report state
  List<ReportGroupNode> rootGroups = [];

  int get pageSize => bundle.definition.defaultPageSize;

  Future<void> init() async {
    sortColumn = bundle.definition.defaultSortColumn;
    sortDir = bundle.definition.defaultSortDir;
    for (final f in bundle.filters) {
      if (f.defaultValue == null) continue;
      filterValues[f.filterKey] = f.isDateRange ? _parseDefaultDateRange(f.defaultValue!) : f.defaultValue;
    }
    await refresh();
  }

  Future<void> refresh() async {
    isLoading = true;
    try {
      if (bundle.isGrouped) {
        await _loadRootGroups();
      } else if (bundle.definition.isMatrix) {
        await _loadAllForMatrix();
      } else {
        await _loadFirstPage();
        totals = await repository.fetchTotals(bundle: bundle, filterValues: filterValues);
      }
    } finally {
      isLoading = false;
    }
  }

  // MATRIX reports are always a small, pre-aggregated result set (see
  // design doc) — fetched in full, no pagination. items holds the
  // normalized rows; SakalReportMatrixTable pivots them client-side.
  static const int _matrixSafetyCap = 5000;

  Future<void> _loadAllForMatrix() async {
    final page = await repository.fetchPage(
      bundle: bundle,
      filterValues: filterValues,
      sortColumn: sortColumn,
      sortDir: sortDir,
      limit: _matrixSafetyCap,
      offset: 0,
    );
    items = page.rows;
    hasMore = false;
    totalCount = page.rows.length;
  }

  Future<void> setSort(String column) async {
    if (sortColumn == column) {
      sortDir = sortDir == 'ASC' ? 'DESC' : 'ASC';
    } else {
      sortColumn = column;
      sortDir = 'ASC';
    }
    await refresh();
  }

  Future<void> applyFilters(Map<String, dynamic> newValues) async {
    filterValues = newValues;
    await refresh();
  }

  // ---- Ungrouped detail-row paging ----------------------------------

  Future<void> _loadFirstPage() async {
    final page = await repository.fetchPage(
      bundle: bundle,
      filterValues: filterValues,
      sortColumn: sortColumn,
      sortDir: sortDir,
      limit: pageSize,
      offset: 0,
      wantCount: true,
    );
    items = page.rows;
    totalCount = page.totalCount;
    _offset = page.rows.length;
    hasMore = page.rows.length == pageSize;
  }

  Future<void> loadMore() async {
    if (!hasMore || isLoadingMore || isLoading) return;
    isLoadingMore = true;
    try {
      final page = await repository.fetchPage(
        bundle: bundle,
        filterValues: filterValues,
        sortColumn: sortColumn,
        sortDir: sortDir,
        limit: pageSize,
        offset: _offset,
      );
      items = [...items, ...page.rows];
      _offset += page.rows.length;
      hasMore = page.rows.length == pageSize;
    } finally {
      isLoadingMore = false;
    }
  }

  // ---- Grouped tree ---------------------------------------------------

  Future<void> _loadRootGroups() async {
    final level1 = bundle.groupLevels.first;
    final rows = await repository.fetchGroupSummary(bundle: bundle, level: level1, filterValues: filterValues);
    rootGroups = rows
        .map((r) => ReportGroupNode(
              summaryRow: r,
              levelNo: level1.levelNo,
              ancestorKeys: {level1.groupByColumn: r[level1.groupByColumn].toString()},
            ))
        .toList();
  }

  Future<void> expandNode(ReportGroupNode node) async {
    if (node.expanded || node.loading) return;
    node.loading = true;
    try {
      final nextLevelIdx = node.levelNo; // levelNo is 1-based; groupLevels[levelNo] is the next level
      if (nextLevelIdx < bundle.groupLevels.length) {
        final nextLevel = bundle.groupLevels[nextLevelIdx];
        final rows = await repository.fetchGroupSummary(
          bundle: bundle,
          level: nextLevel,
          filterValues: filterValues,
          ancestorKeys: node.ancestorKeys,
        );
        node.childGroups = rows
            .map((r) => ReportGroupNode(
                  summaryRow: r,
                  levelNo: nextLevel.levelNo,
                  ancestorKeys: {...node.ancestorKeys, nextLevel.groupByColumn: r[nextLevel.groupByColumn].toString()},
                ))
            .toList();
      } else {
        final page = await repository.fetchPage(
          bundle: bundle,
          filterValues: filterValues,
          sortColumn: sortColumn,
          sortDir: sortDir,
          limit: pageSize,
          offset: 0,
          extraParams: node.ancestorKeys.map((k, v) => MapEntry(k, 'eq.$v')),
        );
        node.childDetailRows = page.rows;
        node.childDetailOffset = page.rows.length;
        node.childDetailHasMore = page.rows.length == pageSize;
      }
      node.expanded = true;
    } finally {
      node.loading = false;
    }
  }

  Future<void> loadMoreDetailForNode(ReportGroupNode node) async {
    if (!node.childDetailHasMore || node.childDetailLoadingMore) return;
    node.childDetailLoadingMore = true;
    try {
      final page = await repository.fetchPage(
        bundle: bundle,
        filterValues: filterValues,
        sortColumn: sortColumn,
        sortDir: sortDir,
        limit: pageSize,
        offset: node.childDetailOffset,
        extraParams: node.ancestorKeys.map((k, v) => MapEntry(k, 'eq.$v')),
      );
      node.childDetailRows = [...?node.childDetailRows, ...page.rows];
      node.childDetailOffset += page.rows.length;
      node.childDetailHasMore = page.rows.length == pageSize;
    } finally {
      node.childDetailLoadingMore = false;
    }
  }

  /// Grand total for a grouped report — summed client-side from the
  /// already-loaded, already-small level-1 summary rows (free, no extra
  /// query — see design doc). Null until root groups have loaded.
  ReportRow? get groupedGrandTotal {
    if (rootGroups.isEmpty) return null;
    final result = <String, dynamic>{};
    for (final col in bundle.aggregateColumns) {
      num sum = 0;
      for (final node in rootGroups) {
        final v = node.summaryRow[col.columnKey];
        if (v is num) sum += v;
      }
      result[col.columnKey] = sum;
    }
    return result;
  }

  Map<String, DateTime> _parseDefaultDateRange(String token) {
    final now = DateTime.now();
    switch (token) {
      case 'THIS_MONTH':
        return {'from': DateTime(now.year, now.month, 1), 'to': DateTime(now.year, now.month + 1, 0)};
      case 'LAST_30_DAYS':
        return {'from': now.subtract(const Duration(days: 30)), 'to': now};
      default:
        return {'from': now, 'to': now};
    }
  }
}
