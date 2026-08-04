import 'report_models.dart';
import 'report_repository.dart';

/// Shared pivot result — computed once, consumed by both
/// [SakalReportMatrixTable] (on-screen) and [ReportExcelExport]'s matrix
/// path (download) so the two never drift out of sync with each other.
class ReportMatrixData {
  final List<String> rowKeysSorted;
  final Map<String, List<dynamic>> rowKeyValues;
  final List<String> dimensionValues;
  final Map<String, num> cells;
  final Map<String, num> rowTotals;
  final Map<String, num> columnTotals;
  final num grandTotal;

  const ReportMatrixData({
    required this.rowKeysSorted,
    required this.rowKeyValues,
    required this.dimensionValues,
    required this.cells,
    required this.rowTotals,
    required this.columnTotals,
    required this.grandTotal,
  });
}

/// Pivots a MATRIX report's normalized rows — see
/// sakal/docs/reporting_engine_design.md and sakal_report_matrix_table.dart's
/// own doc comment for the column-flag conventions this relies on
/// (isPivotRowGroup / isPivotDimension / isPivotMeasure).
ReportMatrixData pivotReportRows({
  required List<ReportColumn> rowGroupCols,
  required ReportColumn dimensionCol,
  required ReportColumn measureCol,
  required List<ReportRow> rows,
}) {
  final rowKeyValues = <String, List<dynamic>>{};
  final dimensionSet = <String>{};
  final cells = <String, num>{};
  final rowTotals = <String, num>{};
  final columnTotals = <String, num>{};
  num grandTotal = 0;

  for (final row in rows) {
    final values = rowGroupCols.map((c) => row[c.columnKey]).toList();
    final rowKey = values.join('|');
    rowKeyValues[rowKey] = values;
    final dimValue = '${row[dimensionCol.columnKey]}';
    dimensionSet.add(dimValue);
    final measure = (row[measureCol.columnKey] as num?) ?? 0;
    final cellKey = '$rowKey||$dimValue';
    cells[cellKey] = (cells[cellKey] ?? 0) + measure;
    rowTotals[rowKey] = (rowTotals[rowKey] ?? 0) + measure;
    columnTotals[dimValue] = (columnTotals[dimValue] ?? 0) + measure;
    grandTotal += measure;
  }

  final sortedRowKeys = rowKeyValues.keys.toList()..sort();
  final sortedDims = dimensionSet.toList()..sort();

  return ReportMatrixData(
    rowKeysSorted: sortedRowKeys,
    rowKeyValues: rowKeyValues,
    dimensionValues: sortedDims,
    cells: cells,
    rowTotals: rowTotals,
    columnTotals: columnTotals,
    grandTotal: grandTotal,
  );
}

/// Finds the report's declared row-group/dimension/measure columns.
/// Returns null if any are missing (same "misconfigured matrix report"
/// guard SakalReportMatrixTable itself uses).
class MatrixPivotColumns {
  final List<ReportColumn> rowGroupCols;
  final ReportColumn dimensionCol;
  final ReportColumn measureCol;
  const MatrixPivotColumns({required this.rowGroupCols, required this.dimensionCol, required this.measureCol});
}

MatrixPivotColumns? findMatrixPivotColumns(List<ReportColumn> columns) {
  final rowGroupCols = columns.where((c) => c.isPivotRowGroup).toList();
  ReportColumn? dimensionCol;
  ReportColumn? measureCol;
  for (final c in columns) {
    if (c.isPivotDimension) dimensionCol ??= c;
    if (c.isPivotMeasure) measureCol ??= c;
  }
  if (rowGroupCols.isEmpty || dimensionCol == null || measureCol == null) return null;
  return MatrixPivotColumns(rowGroupCols: rowGroupCols, dimensionCol: dimensionCol, measureCol: measureCol);
}
