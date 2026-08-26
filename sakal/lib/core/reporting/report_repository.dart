import 'package:dio/dio.dart';
import '../network/dio_client.dart';
import 'report_models.dart';

/// One row of report data, or a group-summary row — both are just JSON
/// maps keyed by column_key, since a report's columns are only known at
/// runtime (see report_models.dart). No typed row model on purpose: the
/// whole point of the DB-driven registry is that a new report needs no
/// new Dart code, including no new row type.
typedef ReportRow = Map<String, dynamic>;

class ReportPage {
  final List<ReportRow> rows;
  final int? totalCount; // null when the report doesn't request an exact/estimated count
  const ReportPage({required this.rows, this.totalCount});
}

/// Fetches report definitions (+columns+filters+group levels) and report
/// data from the report's own backing VIEW/STABLE function. See
/// sakal/docs/reporting_engine_design.md's "Backend design" section —
/// every report is still a normal, typed, per-report SQL object; this
/// class only builds the generic GET querystring around it (filters,
/// sort, pagination), it never constructs SQL itself.
class ReportRepository {
  const ReportRepository();

  Future<ReportBundle> fetchBundle({
    required String reportKey,
    required String clientId,
    required String companyId,
  }) async {
    final defRes = await DioClient.instance.get('/ric_report_definitions', queryParameters: {
      'client_id': 'eq.$clientId',
      'company_id': 'eq.$companyId',
      'report_key': 'eq.$reportKey',
      'is_active': 'eq.true',
      'is_deleted': 'eq.false',
      'select': '*',
      'limit': '1',
    });
    final defList = List<Map<String, dynamic>>.from(defRes.data as List);
    if (defList.isEmpty) {
      throw Exception('Report "$reportKey" is not configured for this company.');
    }
    final definition = ReportDefinition.fromJson(defList.first);

    final results = await Future.wait([
      DioClient.instance.get('/ric_report_columns', queryParameters: {
        'client_id': 'eq.$clientId',
        'company_id': 'eq.$companyId',
        'report_id': 'eq.${definition.id}',
        'is_active': 'eq.true',
        'select': '*',
        'order': 'sort_order.asc',
      }),
      DioClient.instance.get('/ric_report_filters', queryParameters: {
        'client_id': 'eq.$clientId',
        'company_id': 'eq.$companyId',
        'report_id': 'eq.${definition.id}',
        'is_active': 'eq.true',
        'select': '*',
        'order': 'sort_order.asc',
      }),
      DioClient.instance.get('/ric_report_group_levels', queryParameters: {
        'client_id': 'eq.$clientId',
        'company_id': 'eq.$companyId',
        'report_id': 'eq.${definition.id}',
        'select': '*',
        'order': 'level_no.asc',
      }),
    ]);

    return ReportBundle(
      definition: definition,
      columns: List<Map<String, dynamic>>.from(results[0].data as List).map(ReportColumn.fromJson).toList(),
      filters: List<Map<String, dynamic>>.from(results[1].data as List).map(ReportFilter.fromJson).toList(),
      groupLevels:
          List<Map<String, dynamic>>.from(results[2].data as List).map(ReportGroupLevel.fromJson).toList(),
    );
  }

  /// A page of the report's own detail rows (source_object), respecting
  /// filters + sort + limit/offset. [extraParams] lets a caller add
  /// ad-hoc eq. filters on top of the report's declared ones — used when
  /// drilling into a group (filter by that group's own key column) or a
  /// group's own summary_source_object (same shape, different target).
  Future<ReportPage> fetchPage({
    required ReportBundle bundle,
    required String clientId,
    required String companyId,
    required Map<String, dynamic> filterValues,
    String? sortColumn,
    String? sortDir,
    required int limit,
    required int offset,
    Map<String, String>? extraParams,
    String? sourceObjectOverride,
    String? sourceTypeOverride,
    bool wantCount = false,
    // false for a fetch whose target object has a DIFFERENT column shape
    // than the report's main detail feed (fetchTotals — always exactly one
    // row, sorting is meaningless anyway) — otherwise this method falls
    // back to bundle.definition.defaultSortColumn, which is only ever
    // guaranteed to exist on the DETAIL feed's own columns. Applying it to
    // an unrelated aggregate FUNCTION's result (e.g. fn_pending_bills_totals,
    // whose RETURNS TABLE has no trans_date at all) makes PostgREST try to
    // ORDER BY a column that doesn't exist on that function's row type,
    // surfaced as "column record.<col> does not exist" — caught live
    // testing the pilots for real.
    bool applyDefaultSort = true,
  }) async {
    final def = bundle.definition;
    final sourceObject = sourceObjectOverride ?? def.sourceObject;
    final sourceType = sourceTypeOverride ?? def.sourceType;
    final path = sourceType == 'FUNCTION' ? '/rpc/$sourceObject' : '/$sourceObject';

    final params = _buildFilterParams(bundle.filters, filterValues, sourceType);
    // Every report-backing FUNCTION requires p_client_id/p_company_id as
    // its first two (non-default) arguments — a GET-style RPC call never
    // gets these from RLS/JWT automatically the way a VIEW does (a VIEW
    // runs with invoker rights so the base table's own auth_rw_<table>
    // policy scopes it for free; a STABLE function's own WHERE clause has
    // to be told explicitly). Missing this produced exactly the "no
    // matches were found in the schema cache" error PostgREST gives when
    // no overload matches the supplied argument set.
    if (sourceType == 'FUNCTION') {
      params['p_client_id'] = clientId;
      params['p_company_id'] = companyId;
    }
    if (extraParams != null) params.addAll(extraParams);
    params['select'] = '*';
    params['limit'] = '$limit';
    params['offset'] = '$offset';
    final col = sortColumn ?? (applyDefaultSort ? def.defaultSortColumn : null);
    final dir = (sortDir ?? def.defaultSortDir ?? 'ASC').toLowerCase();
    if (col != null) params['order'] = '$col.$dir';

    final headers = <String, String>{};
    if (wantCount) {
      headers['Prefer'] = def.useExactCount ? 'count=exact' : 'count=estimated';
    }

    final res = await DioClient.instance.get(
      path,
      queryParameters: params,
      options: headers.isEmpty ? null : Options(headers: headers),
    );
    final rows = List<Map<String, dynamic>>.from(res.data as List);

    int? total;
    if (wantCount) {
      final range = res.headers.value('content-range');
      if (range != null && range.contains('/')) {
        final totalStr = range.split('/').last;
        total = totalStr == '*' ? null : int.tryParse(totalStr);
      }
    }
    return ReportPage(rows: rows, totalCount: total);
  }

  /// The report-level totals bar — a single-row aggregate query,
  /// independent of pagination (see design doc's "Report totals" section).
  /// Returns null when the report has no totals_source_object.
  ///
  /// ALWAYS called as a FUNCTION, never a VIEW — a plain VIEW that
  /// already does `SELECT SUM(x) FROM ...` has collapsed away the very
  /// columns (trans_date, etc.) PostgREST would need to filter on, since
  /// PostgREST applies `?col=op.val` filters to a relation's OWN output
  /// columns, which happens AFTER a view's internal aggregation has
  /// already run. A STABLE function sidesteps this: filter values arrive
  /// as real function arguments and get applied inside the function's own
  /// WHERE clause, BEFORE it aggregates — the only way a totals/summary
  /// query can stay consistent with whatever the user has filtered by.
  /// (Caught during implementation, before either pilot's SQL was
  /// written — an earlier draft of this method called totals_source_object
  /// as a VIEW, which would have silently ignored every filter.)
  Future<ReportRow?> fetchTotals({
    required ReportBundle bundle,
    required String clientId,
    required String companyId,
    required Map<String, dynamic> filterValues,
    String? totalsSourceObjectOverride,
    // Bare column-name → raw value, same shape as ReportDataController's
    // own fixedParams — since this always targets a FUNCTION, each pair
    // is p_-prefixed (no 'eq.' operator, a real RPC argument) before being
    // handed to fetchPage, mirroring ancestorKeys' own FUNCTION-vs-VIEW
    // formatting split above.
    Map<String, String>? extraParams,
  }) async {
    final totalsObject = totalsSourceObjectOverride ?? bundle.definition.totalsSourceObject;
    if (totalsObject == null) return null;
    final page = await fetchPage(
      bundle: bundle,
      clientId: clientId,
      companyId: companyId,
      filterValues: filterValues,
      limit: 1,
      offset: 0,
      sourceObjectOverride: totalsObject,
      sourceTypeOverride: 'FUNCTION',
      applyDefaultSort: false,
      extraParams: extraParams?.map((k, v) => MapEntry('p_$k', v)),
    );
    return page.rows.isEmpty ? null : page.rows.first;
  }

  /// One grouping level's summary rows — full (unpaginated) fetch, see
  /// design doc's "Fetch pattern (on screen)". [ancestorKeys] filters to a
  /// specific parent group's own key value(s) when expanding a nested
  /// level; empty for level 1 (the top of the tree).
  ///
  /// ALWAYS called as a FUNCTION, same reasoning as fetchTotals above —
  /// `summary_source_object` already does its own internal GROUP BY, so
  /// PostgREST-level column filtering can't reach the pre-aggregation
  /// rows. [ancestorKeys] are keyed by BARE column name (e.g.
  /// `account_id`, matching `ReportGroupNode.ancestorKeys`'s own storage
  /// format, shared with the deepest-level detail fetch which needs the
  /// bare name for a real PostgREST column filter) — this method prefixes
  /// each key with `p_` before sending it, since a function argument
  /// follows this codebase's universal `p_`-prefixed parameter naming
  /// convention, not the bare column name. Getting this prefix wrong
  /// silently drops the filter (PostgREST ignores an unrecognized RPC
  /// query param rather than erroring) — caught while writing the pilot
  /// report's own summary functions, before either one ever ran.
  Future<List<ReportRow>> fetchGroupSummary({
    required ReportBundle bundle,
    required String clientId,
    required String companyId,
    required ReportGroupLevel level,
    required Map<String, dynamic> filterValues,
    Map<String, String> ancestorKeys = const {},
  }) async {
    final page = await fetchPage(
      bundle: bundle,
      clientId: clientId,
      companyId: companyId,
      filterValues: filterValues,
      sortColumn: level.groupLabelColumn,
      sortDir: 'ASC',
      limit: 10000, // group-summary rows are already aggregated — this is a safety cap, not real pagination
      offset: 0,
      extraParams: ancestorKeys.map((k, v) => MapEntry('p_$k', v)),
      sourceObjectOverride: level.summarySourceObject,
      sourceTypeOverride: 'FUNCTION',
    );
    return page.rows;
  }

  /// Fetches the FULL filtered/sorted detail set for export, ignoring
  /// on-screen pagination — capped at max_export_rows (see design doc's
  /// Performance section). Returns null if the true row count exceeds the
  /// cap, so the caller can prompt "narrow your filters" instead of
  /// attempting an unbounded export.
  Future<List<ReportRow>?> fetchAllForExport({
    required ReportBundle bundle,
    required String clientId,
    required String companyId,
    required Map<String, dynamic> filterValues,
    String? sortColumn,
    String? sortDir,
    String? sourceObjectOverride,
  }) async {
    final cap = bundle.definition.maxExportRows;
    final page = await fetchPage(
      bundle: bundle,
      clientId: clientId,
      companyId: companyId,
      filterValues: filterValues,
      sortColumn: sortColumn,
      sortDir: sortDir,
      limit: cap + 1,
      offset: 0,
      sourceObjectOverride: sourceObjectOverride,
    );
    if (page.rows.length > cap) return null;
    return page.rows;
  }

  /// Builds the PostgREST querystring for a report's declared filters.
  /// VIEW sources use PostgREST column-filter operators (eq./gte./lte./
  /// ilike.); FUNCTION sources pass literal argument values instead (a
  /// GET-style RPC call's query params ARE the function's own parameters,
  /// not column filters) — DATE_RANGE synthesizes `${param}_from`/
  /// `${param}_to` argument names in that case.
  Map<String, dynamic> _buildFilterParams(
    List<ReportFilter> filters,
    Map<String, dynamic> values,
    String sourceType,
  ) {
    final params = <String, dynamic>{};
    for (final f in filters) {
      final value = values[f.filterKey];
      if (value == null) continue;
      final isFunction = sourceType == 'FUNCTION';

      if (f.isDateRange && value is Map) {
        final from = value['from'];
        final to = value['to'];
        if (isFunction) {
          if (from != null) params['p_${f.paramTarget}_from'] = _fmt(from);
          if (to != null) params['p_${f.paramTarget}_to'] = _fmt(to);
        } else {
          final conditions = <String>[];
          if (from != null) conditions.add('gte.${_fmt(from)}');
          if (to != null) conditions.add('lte.${_fmt(to)}');
          if (conditions.isNotEmpty) params[f.paramTarget] = conditions;
        }
        continue;
      }

      if (isFunction) {
        params['p_${f.paramTarget}'] = _fmt(value);
        continue;
      }

      switch (f.filterType) {
        case 'TEXT':
          params[f.paramTarget] = 'ilike.*${_fmt(value)}*';
          break;
        case 'DATE':
        case 'DROPDOWN_STATIC':
        case 'DROPDOWN_LOOKUP':
        case 'ACCOUNT_PICKER':
        case 'PRODUCT_PICKER':
        case 'BOOLEAN':
        default:
          params[f.paramTarget] = 'eq.${_fmt(value)}';
      }
    }
    return params;
  }

  String _fmt(dynamic v) {
    if (v is DateTime) return v.toIso8601String().split('T').first;
    return v.toString();
  }
}
