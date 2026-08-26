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
  ReportDataController({
    required this.repository,
    required this.bundle,
    required this.clientId,
    required this.companyId,
    this.fixedParams,
  });

  final ReportRepository repository;
  final ReportBundle bundle;
  final String clientId;
  final String companyId;

  // A hidden, non-user-editable filter applied on EVERY fetch (detail page,
  // load-more, and totals) alongside whatever's in filterValues — bare
  // column-name → raw value. Introduced for Product Movement Analysis'
  // own job_id scoping (a report screen reached via a notification's deep
  // link, not through a normal declared ric_report_filters row — see
  // ReportScreen's own job_id handling) but generic: any future report
  // needing a fixed, invisible scope key can reuse this the same way.
  final Map<String, String>? fixedParams;

  String? sortColumn;
  String? sortDir; // ASC | DESC
  Map<String, dynamic> filterValues = {};

  // 'BASE' | 'LOCAL' — only meaningful when bundle.definition.hasCurrencyToggle.
  // Scoped to TABULAR/MATRIX (the report shapes this report's own fetch
  // methods below cover) — grouped-tree fetches (_loadRootGroups/
  // expandNode/loadMoreDetailForNode) deliberately don't consult this yet,
  // see report_models.dart's ReportDefinition.sourceObjectLocal doc.
  String currencyMode = 'BASE';

  bool isLoading = false;
  ReportRow? totals;

  // NEW: when bundle.definition.autoLoad is false, init() resolves default
  // filter values but does NOT fire the first fetch — the screen shows a
  // "Run Report" prompt instead, and this flips true once the user (or
  // the filter bar's own Apply) actually triggers refresh() for the first
  // time. Always true for every existing auto-loading report, so their
  // behavior is unaffected.
  bool hasRunOnce = false;

  // Ungrouped-report state
  List<ReportRow> items = [];
  bool isLoadingMore = false;
  bool hasMore = true;
  int? totalCount;
  int _offset = 0;

  // Grouped-report state
  List<ReportGroupNode> rootGroups = [];

  int get pageSize => bundle.definition.defaultPageSize;

  // null when currencyMode == 'BASE' (fetchPage/fetchTotals/
  // fetchAllForExport already fall back to the definition's own default
  // object when no override is given, so 'BASE' needs no override at all).
  String? get _sourceOverride => currencyMode == 'LOCAL' ? bundle.definition.sourceObjectLocal : null;
  String? get _totalsOverride => currencyMode == 'LOCAL' ? bundle.definition.totalsSourceObjectLocal : null;

  Future<void> setCurrencyMode(String mode) async {
    if (currencyMode == mode) return;
    currencyMode = mode;
    await refresh();
  }

  Future<void> init() async {
    sortColumn = bundle.definition.defaultSortColumn;
    sortDir = bundle.definition.defaultSortDir;
    for (final f in bundle.filters) {
      if (f.defaultValue == null) continue;
      if (f.isDateRange) {
        filterValues[f.filterKey] = _parseDefaultDateRange(f.defaultValue!);
      } else if (f.filterType == 'DATE') {
        // Same reasoning as DATE_RANGE just above — the DATE filter widget
        // and _buildFilterParams both expect a real DateTime, not the raw
        // TEXT default_value stores (e.g. 'TODAY' for Balance Sheet's own
        // As Of Date filter, the first single-DATE filter with a default in
        // this engine).
        filterValues[f.filterKey] = _parseDefaultDate(f.defaultValue!);
      } else if (f.filterType == 'BOOLEAN') {
        // default_value is always TEXT in ric_report_filters (e.g. 'false') —
        // the BOOLEAN filter widget casts this as `bool?`, so it must be
        // parsed here, not passed through as a raw String.
        filterValues[f.filterKey] = f.defaultValue!.toLowerCase() == 'true';
      } else {
        filterValues[f.filterKey] = f.defaultValue;
      }
    }
    if (!bundle.definition.autoLoad) return;
    await refresh();
  }

  Future<void> refresh() async {
    isLoading = true;
    hasRunOnce = true;
    try {
      if (bundle.isGrouped) {
        await _loadRootGroups();
      } else if (bundle.definition.isMatrix) {
        await _loadAllForMatrix();
      } else if (bundle.definition.isHierarchical) {
        await _loadAllForHierarchical();
      } else {
        await _loadFirstPage();
        totals = await repository.fetchTotals(
            bundle: bundle, clientId: clientId, companyId: companyId, filterValues: filterValues,
            totalsSourceObjectOverride: _totalsOverride, extraParams: fixedParams);
      }
    } finally {
      isLoading = false;
    }
  }

  // HIERARCHICAL reports (P&L) are, like MATRIX, a small pre-computed
  // result set — fetched once in full, no pagination. Unlike MATRIX
  // (whose Total row/column is cheap client-side arithmetic over the
  // pivoted cells), the Income/Expense/Net Profit footer here comes from
  // a real totals_source_object call, same as a plain TABULAR report —
  // fn_pl_totals_base/_local reuses fn_pl_tree_base/_local's own numbers
  // rather than re-deriving the rollup a third time, so the footer can
  // never disagree with the tree.
  Future<void> _loadAllForHierarchical() async {
    final page = await repository.fetchPage(
      bundle: bundle,
      clientId: clientId,
      companyId: companyId,
      filterValues: filterValues,
      sortColumn: sortColumn,
      sortDir: sortDir,
      limit: _matrixSafetyCap,
      offset: 0,
      sourceObjectOverride: _sourceOverride,
    );
    items = page.rows;
    hasMore = false;
    totalCount = page.rows.length;
    totals = await repository.fetchTotals(
        bundle: bundle, clientId: clientId, companyId: companyId, filterValues: filterValues,
        totalsSourceObjectOverride: _totalsOverride);
  }

  // MATRIX reports are always a small, pre-aggregated result set (see
  // design doc) — fetched in full, no pagination. items holds the
  // normalized rows; SakalReportMatrixTable pivots them client-side.
  static const int _matrixSafetyCap = 5000;

  Future<void> _loadAllForMatrix() async {
    final page = await repository.fetchPage(
      bundle: bundle,
      clientId: clientId,
      companyId: companyId,
      filterValues: filterValues,
      sortColumn: sortColumn,
      sortDir: sortDir,
      limit: _matrixSafetyCap,
      offset: 0,
      sourceObjectOverride: _sourceOverride,
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
      clientId: clientId,
      companyId: companyId,
      filterValues: filterValues,
      sortColumn: sortColumn,
      sortDir: sortDir,
      limit: pageSize,
      offset: 0,
      wantCount: true,
      sourceObjectOverride: _sourceOverride,
      extraParams: fixedParams?.map((k, v) => MapEntry(k, 'eq.$v')),
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
        clientId: clientId,
        companyId: companyId,
        filterValues: filterValues,
        sortColumn: sortColumn,
        sortDir: sortDir,
        limit: pageSize,
        offset: _offset,
        sourceObjectOverride: _sourceOverride,
        extraParams: fixedParams?.map((k, v) => MapEntry(k, 'eq.$v')),
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
    final rows = await repository.fetchGroupSummary(
        bundle: bundle, clientId: clientId, companyId: companyId, level: level1, filterValues: filterValues);
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
          clientId: clientId,
          companyId: companyId,
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
          clientId: clientId,
          companyId: companyId,
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

  // Expand every currently-collapsed node, recursing into nested levels as
  // each parent's children arrive — sequential, not Future.wait, so a
  // report with many groups doesn't fire them all as simultaneous RPC
  // calls. Only opens each node to its already-lazy first page of
  // detail rows (same as tapping it once), never bulk-loads every page —
  // "expand" and "load everything" are deliberately different operations.
  Future<void> expandAll() async {
    Future<void> walk(List<ReportGroupNode> nodes) async {
      for (final node in nodes) {
        if (!node.expanded) await expandNode(node);
        if (node.childGroups != null) await walk(node.childGroups!);
      }
    }

    await walk(rootGroups);
  }

  void collapseAll() {
    void walk(List<ReportGroupNode> nodes) {
      for (final node in nodes) {
        node.expanded = false;
        if (node.childGroups != null) walk(node.childGroups!);
      }
    }

    walk(rootGroups);
  }

  Future<void> loadMoreDetailForNode(ReportGroupNode node) async {
    if (!node.childDetailHasMore || node.childDetailLoadingMore) return;
    node.childDetailLoadingMore = true;
    try {
      final page = await repository.fetchPage(
        bundle: bundle,
        clientId: clientId,
        companyId: companyId,
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

  DateTime _parseDefaultDate(String token) {
    final now = DateTime.now();
    switch (token) {
      case 'TODAY':
        return DateTime(now.year, now.month, now.day);
      default:
        return now;
    }
  }

  Map<String, DateTime> _parseDefaultDateRange(String token) {
    final now = DateTime.now();
    switch (token) {
      case 'THIS_MONTH':
        return {'from': DateTime(now.year, now.month, 1), 'to': DateTime(now.year, now.month + 1, 0)};
      case 'LAST_30_DAYS':
        return {'from': now.subtract(const Duration(days: 30)), 'to': now};
      case 'LAST_90_DAYS':
        return {'from': now.subtract(const Duration(days: 90)), 'to': now};
      default:
        return {'from': now, 'to': now};
    }
  }
}
