import 'report_models.dart';
import 'report_repository.dart';

/// Marker key on a synthetic row produced by [prepareGroupedExportRows] —
/// both exporters render a row carrying this as a bold subtotal line
/// instead of a normal data row.
const String kExportSubtotalMarker = '__isSubtotal';

/// Prepares a grouped report's detail rows for export: sorts by the
/// level-1 group-by column so each group's rows are contiguous, then
/// inserts a subtotal row after each group's run (see design doc's
/// "Export (PDF/Excel): always renders fully expanded ... interleaving
/// subtotal rows after each group"). Ungrouped reports pass through
/// unchanged.
///
/// v1 scope: only the OUTERMOST (level 1) grouping is interleaved into
/// export output — this is the concrete scenario the engine was built to
/// answer ("subtotal per Product Group, plus a report grand total").
/// Deeper levels (2+) still contribute to the on-screen expand/collapse
/// tree correctly; interleaving their own subtotal rows into a flat
/// export too is a natural, self-contained follow-up once a report
/// actually needs 2+ level export interleaving, not required for the
/// pilot this ships with.
List<ReportRow> prepareGroupedExportRows(ReportBundle bundle, List<ReportRow> detailRows) {
  if (!bundle.isGrouped) return detailRows;
  final level1 = bundle.groupLevels.first;

  final grouped = <String, List<ReportRow>>{};
  for (final row in detailRows) {
    final key = '${row[level1.groupByColumn]}';
    grouped.putIfAbsent(key, () => []).add(row);
  }
  final sortedKeys = grouped.keys.toList()..sort();

  final result = <ReportRow>[];
  for (final key in sortedKeys) {
    final rowsInGroup = grouped[key]!;
    result.addAll(rowsInGroup);

    final subtotal = <String, dynamic>{kExportSubtotalMarker: true};
    for (final col in bundle.aggregateColumns) {
      num sum = 0;
      for (final r in rowsInGroup) {
        final v = r[col.columnKey];
        if (v is num) sum += v;
      }
      subtotal[col.columnKey] = sum;
    }
    subtotal[level1.groupLabelColumn] = rowsInGroup.first[level1.groupLabelColumn];
    result.add(subtotal);
  }
  return result;
}

bool isExportSubtotalRow(ReportRow row) => row[kExportSubtotalMarker] == true;
