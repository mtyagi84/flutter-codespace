import 'backend_verifier.dart';

/// Compares a report's actual backend output against an independently
/// computed expected value — per the plan, always by querying a
/// lower-level, already-trusted table (e.g. summing `ril_stock_ledger` or
/// `rid_finance_lines` directly), never by re-implementing the report's own
/// formula in test code (that risks silently re-implementing the same bug
/// the report has, e.g. FEFO/weighted-average-cost/multi-currency logic).
class ReportDiff {
  final BackendVerifier verifier;
  ReportDiff(this.verifier);

  /// Fetches a report's own backend RPC/view output directly over REST —
  /// fast and deterministic, avoiding fragile UI-table-cell text scraping
  /// (number formatting, currency symbols, pagination).
  Future<dynamic> fetchReportOutput(String reportRpc, Map<String, dynamic> params) {
    return verifier.rpc(reportRpc, params);
  }

  /// Sums a numeric column across rows from a raw ledger/journal table,
  /// scoped to the QA tenant — the "independent expected value" side of a
  /// diff. Callers pass whatever filters narrow it to the specific
  /// transaction(s) under test (e.g. {'product_id': 'eq.<id>'}).
  Future<double> sumColumn(String table, String column, Map<String, String> filters) async {
    final rows = await verifier.get(table, filters, select: column);
    return rows.fold<double>(0, (sum, row) => sum + ((row[column] as num?)?.toDouble() ?? 0));
  }

  /// Asserts two numeric values match within a small rounding tolerance
  /// (currency math involves multiple rate multiplications — exact
  /// floating-point equality is the wrong bar; a few cents/centimes of
  /// rounding drift is expected and fine, a real leak is not).
  void expectClose(double actual, double expected, {double tolerance = 0.05, String? reason}) {
    final diff = (actual - expected).abs();
    if (diff > tolerance) {
      throw StateError(
        '${reason ?? "Report diff"} failed: actual=$actual expected=$expected '
        'diff=$diff exceeds tolerance=$tolerance',
      );
    }
  }
}
