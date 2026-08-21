/// Data-only models for the reporting engine's DB-driven registry
/// (`ric_report_definitions`/`ric_report_columns`/`ric_report_filters`/
/// `ric_report_group_levels`, migration 116). See
/// `sakal/docs/reporting_engine_design.md` for the full design — these
/// classes are a direct mirror of that migration's columns, nothing more.
class ReportDefinition {
  final String id;
  final String clientId;
  final String companyId;
  final String reportKey;
  final String reportName;
  final String reportType; // TABULAR | MATRIX | HIERARCHICAL
  final String sourceType; // VIEW | FUNCTION
  final String sourceObject;
  final String moduleCode;
  final String? defaultSortColumn;
  final String? defaultSortDir; // ASC | DESC
  final int defaultPageSize;
  final bool useExactCount;
  final int maxExportRows;
  final String? totalsSourceObject;
  // Nullable Base/Local currency-toggle pair (migration 127) — when
  // sourceObjectLocal is set, the report has a same-shape twin object (same
  // column names) in the other currency, and the screen shows a Currency
  // toggle instead of forcing a second report_key. TABULAR/MATRIX only —
  // grouped reports would need ric_report_group_levels to carry its own
  // local variant per level too, deliberately not built yet.
  final String? sourceObjectLocal;
  final String? totalsSourceObjectLocal;
  final bool isActive;
  // Nullable — when set, the filter bar's own date_range filter (if any)
  // is checked against this cap in sakal_report_screen.dart's onApply,
  // before the report ever fetches. Exists because a MATRIX report's
  // column count is driven directly by the date range (e.g. one column
  // per month) — an unbounded range would silently generate an
  // unreasonable number of columns. NULL (every report before this one)
  // means no limit.
  final int? maxDateRangeMonths;
  // NEW: gates whether ReportDataController.init() fires a query
  // automatically on screen open, or waits for an explicit "Run Report"
  // action (sakal_report_screen.dart). Defaults true — every report
  // before this one keeps auto-loading exactly as before; set false only
  // on reports whose row count scales with something unbounded (e.g. the
  // full product catalog) and where every filter is optional, so the
  // worst case ("no filters, click the menu") is the default case, not
  // an edge case.
  final bool autoLoad;

  const ReportDefinition({
    required this.id,
    required this.clientId,
    required this.companyId,
    required this.reportKey,
    required this.reportName,
    required this.reportType,
    required this.sourceType,
    required this.sourceObject,
    required this.moduleCode,
    this.defaultSortColumn,
    this.defaultSortDir,
    required this.defaultPageSize,
    required this.useExactCount,
    required this.maxExportRows,
    this.totalsSourceObject,
    this.sourceObjectLocal,
    this.totalsSourceObjectLocal,
    required this.isActive,
    this.maxDateRangeMonths,
    this.autoLoad = true,
  });

  factory ReportDefinition.fromJson(Map<String, dynamic> j) => ReportDefinition(
        id: j['id'] as String,
        clientId: j['client_id'] as String,
        companyId: j['company_id'] as String,
        reportKey: j['report_key'] as String,
        reportName: j['report_name'] as String,
        reportType: j['report_type'] as String,
        sourceType: j['source_type'] as String,
        sourceObject: j['source_object'] as String,
        moduleCode: j['module_code'] as String,
        defaultSortColumn: j['default_sort_column'] as String?,
        defaultSortDir: j['default_sort_dir'] as String?,
        defaultPageSize: (j['default_page_size'] as num?)?.toInt() ?? 50,
        useExactCount: j['use_exact_count'] as bool? ?? true,
        maxExportRows: (j['max_export_rows'] as num?)?.toInt() ?? 100000,
        totalsSourceObject: j['totals_source_object'] as String?,
        sourceObjectLocal: j['source_object_local'] as String?,
        totalsSourceObjectLocal: j['totals_source_object_local'] as String?,
        isActive: j['is_active'] as bool? ?? true,
        maxDateRangeMonths: (j['max_date_range_months'] as num?)?.toInt(),
        autoLoad: j['auto_load'] as bool? ?? true,
      );

  bool get isTabular => reportType == 'TABULAR';
  bool get isMatrix => reportType == 'MATRIX';
  bool get isHierarchical => reportType == 'HIERARCHICAL';
  bool get hasCurrencyToggle => sourceObjectLocal != null;
}

class ReportColumn {
  final String id;
  final String reportId;
  final String columnKey;
  final String label;
  final String dataType; // TEXT | NUMBER | DATE | BOOLEAN | BADGE
  final String? format;
  final String? align; // LEFT | RIGHT | CENTER
  final bool sortable;
  final bool defaultVisible;
  final double? defaultWidth;
  final int sortOrder;
  final String? aggregateFn; // SUM | AVG | COUNT | MIN | MAX
  final bool isPivotRowGroup;
  final bool isPivotDimension;
  final bool isPivotMeasure;
  final String? currencyCodeColumn;
  final String? drilldownRoute;
  final String? drilldownKeyColumn;

  const ReportColumn({
    required this.id,
    required this.reportId,
    required this.columnKey,
    required this.label,
    required this.dataType,
    this.format,
    this.align,
    required this.sortable,
    required this.defaultVisible,
    this.defaultWidth,
    required this.sortOrder,
    this.aggregateFn,
    required this.isPivotRowGroup,
    required this.isPivotDimension,
    required this.isPivotMeasure,
    this.currencyCodeColumn,
    this.drilldownRoute,
    this.drilldownKeyColumn,
  });

  factory ReportColumn.fromJson(Map<String, dynamic> j) => ReportColumn(
        id: j['id'] as String,
        reportId: j['report_id'] as String,
        columnKey: j['column_key'] as String,
        label: j['label'] as String,
        dataType: j['data_type'] as String,
        format: j['format'] as String?,
        align: j['align'] as String?,
        sortable: j['sortable'] as bool? ?? true,
        defaultVisible: j['default_visible'] as bool? ?? true,
        defaultWidth: (j['default_width'] as num?)?.toDouble(),
        sortOrder: (j['sort_order'] as num?)?.toInt() ?? 0,
        aggregateFn: j['aggregate_fn'] as String?,
        isPivotRowGroup: j['is_pivot_row_group'] as bool? ?? false,
        isPivotDimension: j['is_pivot_dimension'] as bool? ?? false,
        isPivotMeasure: j['is_pivot_measure'] as bool? ?? false,
        currencyCodeColumn: j['currency_code_column'] as String?,
        drilldownRoute: j['drilldown_route'] as String?,
        drilldownKeyColumn: j['drilldown_key_column'] as String?,
      );

  bool get isNumeric => dataType == 'NUMBER';
  bool get hasDrilldown => drilldownRoute != null && drilldownKeyColumn != null;
}

class ReportFilter {
  final String id;
  final String reportId;
  final String filterKey;
  final String label;
  final String filterType; // DATE_RANGE | DATE | DROPDOWN_STATIC | DROPDOWN_LOOKUP | ACCOUNT_PICKER | PRODUCT_PICKER | TEXT | BOOLEAN
  final String? lookupSource;
  final String? lookupLabelColumn;
  final List<Map<String, dynamic>>? staticOptions;
  final String paramTarget;
  final bool required;
  final String? defaultValue;
  final int sortOrder;

  const ReportFilter({
    required this.id,
    required this.reportId,
    required this.filterKey,
    required this.label,
    required this.filterType,
    this.lookupSource,
    this.lookupLabelColumn,
    this.staticOptions,
    required this.paramTarget,
    required this.required,
    this.defaultValue,
    required this.sortOrder,
  });

  factory ReportFilter.fromJson(Map<String, dynamic> j) => ReportFilter(
        id: j['id'] as String,
        reportId: j['report_id'] as String,
        filterKey: j['filter_key'] as String,
        label: j['label'] as String,
        filterType: j['filter_type'] as String,
        lookupSource: j['lookup_source'] as String?,
        lookupLabelColumn: j['lookup_label_column'] as String?,
        staticOptions: j['static_options'] != null
            ? List<Map<String, dynamic>>.from(j['static_options'] as List)
            : null,
        paramTarget: j['param_target'] as String,
        required: j['required'] as bool? ?? false,
        defaultValue: j['default_value'] as String?,
        sortOrder: (j['sort_order'] as num?)?.toInt() ?? 0,
      );

  bool get isDateRange => filterType == 'DATE_RANGE';
}

class ReportGroupLevel {
  final String id;
  final String reportId;
  final int levelNo;
  final String groupByColumn;
  final String groupLabelColumn;
  final String summarySourceObject;

  const ReportGroupLevel({
    required this.id,
    required this.reportId,
    required this.levelNo,
    required this.groupByColumn,
    required this.groupLabelColumn,
    required this.summarySourceObject,
  });

  factory ReportGroupLevel.fromJson(Map<String, dynamic> j) => ReportGroupLevel(
        id: j['id'] as String,
        reportId: j['report_id'] as String,
        levelNo: (j['level_no'] as num).toInt(),
        groupByColumn: j['group_by_column'] as String,
        groupLabelColumn: j['group_label_column'] as String,
        summarySourceObject: j['summary_source_object'] as String,
      );
}

/// The full picture the report screen needs, assembled by [ReportRepository]
/// from 4 separate table fetches into one convenient bundle.
class ReportBundle {
  final ReportDefinition definition;
  final List<ReportColumn> columns;
  final List<ReportFilter> filters;
  final List<ReportGroupLevel> groupLevels; // empty = ungrouped report

  const ReportBundle({
    required this.definition,
    required this.columns,
    required this.filters,
    required this.groupLevels,
  });

  bool get isGrouped => groupLevels.isNotEmpty;
  bool get isTabular => definition.isTabular;
  bool get isMatrix => definition.isMatrix;
  bool get isHierarchical => definition.isHierarchical;
  List<ReportColumn> get visibleColumns => columns.where((c) => c.defaultVisible).toList();
  List<ReportColumn> get aggregateColumns => columns.where((c) => c.aggregateFn != null).toList();
}
