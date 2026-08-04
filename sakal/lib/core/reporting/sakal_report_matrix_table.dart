import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../utils/app_number_format.dart';
import 'report_matrix_pivot.dart';
import 'report_models.dart';
import 'report_repository.dart';

/// Client-side pivot of a normalized `MATRIX` report's rows (see
/// sakal/docs/reporting_engine_design.md — the source_object stays a
/// normal `GROUP BY` VIEW/function; only the pivoting into a wide grid
/// happens here). Convention: [ReportColumn.isPivotDimension] marks the
/// column whose own VALUES become the matrix's dynamic column headers
/// directly (use a human-readable column, e.g. `location_name`, not a
/// raw id) — there's no separate dimension-label column, unlike
/// row-group columns which can be several (all shown as leading columns,
/// keyed by their combined values). Row/column totals and a grand-total
/// corner cell are cheap client-side arithmetic over data already fully
/// loaded in memory — no new fetch pattern.
///
/// The actual pivot arithmetic lives in report_matrix_pivot.dart, shared
/// with ReportExcelExport's matrix path — this widget and the downloaded
/// file must never disagree on what the pivoted numbers are.
class SakalReportMatrixTable extends StatelessWidget {
  final ReportBundle bundle;
  final List<ReportRow> rows;
  final String numberFormat;

  const SakalReportMatrixTable({super.key, required this.bundle, required this.rows, required this.numberFormat});

  static const double _rowGroupColWidth = 160;
  static const double _dimensionColWidth = 120;

  @override
  Widget build(BuildContext context) {
    final pivotCols = findMatrixPivotColumns(bundle.columns);
    if (pivotCols == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('This matrix report is missing a row-group, dimension, or measure column configuration.'),
        ),
      );
    }
    final rowGroupCols = pivotCols.rowGroupCols;
    final pivot = pivotReportRows(
      rowGroupCols: rowGroupCols, dimensionCol: pivotCols.dimensionCol, measureCol: pivotCols.measureCol, rows: rows);

    final totalWidth = rowGroupCols.length * _rowGroupColWidth +
        pivot.dimensionValues.length * _dimensionColWidth +
        _dimensionColWidth; // trailing "Total" column

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: totalWidth,
        child: Column(children: [
          _buildHeaderRow(rowGroupCols, pivot),
          const Divider(height: 1, color: AppColors.border),
          Expanded(
            child: ListView.builder(
              itemCount: pivot.rowKeysSorted.length,
              itemBuilder: (context, i) => _buildDataRow(rowGroupCols, pivot, pivot.rowKeysSorted[i]),
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          _buildTotalsRow(rowGroupCols, pivot),
        ]),
      ),
    );
  }

  Widget _buildHeaderRow(List<ReportColumn> rowGroupCols, ReportMatrixData pivot) => Container(
        color: AppColors.primary,
        child: Row(children: [
          ...rowGroupCols.map((c) => SizedBox(
                width: _rowGroupColWidth,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  child: Text(c.label.toUpperCase(),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 10.5)),
                ),
              )),
          ...pivot.dimensionValues.map((d) => SizedBox(
                width: _dimensionColWidth,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  child: Text(d, textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 10.5)),
                ),
              )),
          SizedBox(
            width: _dimensionColWidth,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: Text('TOTAL', textAlign: TextAlign.right,
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 10.5)),
            ),
          ),
        ]),
      );

  Widget _buildDataRow(List<ReportColumn> rowGroupCols, ReportMatrixData pivot, String rowKey) {
    final values = pivot.rowKeyValues[rowKey]!;
    return Container(
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5))),
      child: Row(children: [
        ...List.generate(
          rowGroupCols.length,
          (i) => SizedBox(
            width: _rowGroupColWidth,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Text('${values[i] ?? '—'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            ),
          ),
        ),
        ...pivot.dimensionValues.map((d) {
          final cell = pivot.cells['$rowKey||$d'];
          return SizedBox(
            width: _dimensionColWidth,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Text(cell == null ? '—' : AppNumberFormat.amount(cell, numberFormat),
                  textAlign: TextAlign.right, style: const TextStyle(fontSize: 13)),
            ),
          );
        }),
        SizedBox(
          width: _dimensionColWidth,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Text(AppNumberFormat.amount(pivot.rowTotals[rowKey] ?? 0, numberFormat),
                textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          ),
        ),
      ]),
    );
  }

  Widget _buildTotalsRow(List<ReportColumn> rowGroupCols, ReportMatrixData pivot) => Container(
        color: AppColors.primaryLight.withValues(alpha: 0.12),
        child: Row(children: [
          SizedBox(
            width: rowGroupCols.length * _rowGroupColWidth,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: Text('Total', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
            ),
          ),
          ...pivot.dimensionValues.map((d) => SizedBox(
                width: _dimensionColWidth,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  child: Text(AppNumberFormat.amount(pivot.columnTotals[d] ?? 0, numberFormat),
                      textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
                ),
              )),
          SizedBox(
            width: _dimensionColWidth,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: Text(AppNumberFormat.amount(pivot.grandTotal, numberFormat),
                  textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
            ),
          ),
        ]),
      );
}
