import 'dart:typed_data';
import 'package:excel/excel.dart' as xls;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'report_export_helpers.dart';
import 'report_matrix_pivot.dart';
import 'report_models.dart';
import 'report_repository.dart';
import 'web_download.dart';

/// Saves the finished workbook bytes to disk. On web this bypasses
/// FilePicker.platform.saveFile() (its File System Access API path is
/// timing-sensitive to the activation window of the ORIGINAL button
/// click — see web_download_web.dart) in favor of a plain Blob+anchor
/// download, which has no such restriction. Every other platform is
/// unchanged.
Future<void> _saveWorkbookBytes(List<int> bytes, String filename, String dialogTitle) async {
  if (kIsWeb) {
    downloadBytesOnWeb(bytes, filename);
    return;
  }
  await FilePicker.platform.saveFile(
    dialogTitle: dialogTitle,
    fileName: filename,
    bytes: Uint8List.fromList(bytes),
    type: FileType.custom,
    allowedExtensions: ['xlsx'],
  );
}

/// Excel export for any report. Uses the exact same
/// `xls.Excel.createExcel()` -> `sheet.appendRow()` -> `workbook.encode()`
/// -> `FilePicker.platform.saveFile(bytes: ...)` pipeline already proven
/// working in this codebase (Opening Stock's own template download —
/// `opening_stock_entry_screen.dart`'s `_downloadTemplate()`). The `excel`
/// package was already a dependency before this engine, just never used
/// for a report-shaped multi-row export until now.
///
/// Cells are written as `TextCellValue` only, not the numeric/date
/// `CellValue` subclasses the package also exposes — a deliberate,
/// conservative choice: `TextCellValue` is the one cell type already
/// confirmed working in this exact pinned package version elsewhere in
/// the codebase. Native numeric Excel cells (so a user could sum a column
/// in Excel itself) are a safe follow-up enhancement, not attempted here
/// without a way to verify the additional API surface compiles.
///
/// Same v1 note as report_pdf_export.dart: generation runs synchronously,
/// not via `compute()` — `max_export_rows` already bounds the work.
class ReportExcelExport {
  static Future<void> export({
    required ReportDefinition definition,
    required List<ReportColumn> columns,
    required List<ReportRow> rows,
    ReportRow? totalsRow,
  }) async {
    final workbook = xls.Excel.createExcel();
    final sheetName = workbook.getDefaultSheet()!;
    final sheet = workbook[sheetName];
    final visibleColumns = columns.where((c) => c.defaultVisible).toList();

    sheet.appendRow(visibleColumns.map((c) => xls.TextCellValue(c.label)).toList());

    for (final row in rows) {
      if (isExportSubtotalRow(row)) {
        // Position-independent, same reasoning as report_pdf_export.dart:
        // the synthetic subtotal row only carries a value for its
        // aggregate columns plus the one group-label column.
        sheet.appendRow(visibleColumns.map((c) {
          if (c.aggregateFn != null) return xls.TextCellValue(_cellText(c, row));
          final v = row[c.columnKey];
          return xls.TextCellValue(v != null ? 'Subtotal: $v' : '');
        }).toList());
        continue;
      }
      sheet.appendRow(visibleColumns.map((c) => xls.TextCellValue(_cellText(c, row))).toList());
    }

    if (totalsRow != null) {
      sheet.appendRow(List.generate(visibleColumns.length, (i) {
        final c = visibleColumns[i];
        if (i == 0) return xls.TextCellValue('Total');
        if (c.aggregateFn == null) return xls.TextCellValue('');
        return xls.TextCellValue(_cellText(c, totalsRow));
      }));
    }

    final bytes = workbook.encode();
    if (bytes == null) return;
    final filename = '${definition.reportKey.toLowerCase()}_${DateTime.now().millisecondsSinceEpoch}.xlsx';
    await _saveWorkbookBytes(bytes, filename, 'Save ${definition.reportName}');
  }

  /// MATRIX-report export — writes the already-pivoted wide shape (row
  /// group columns, one column per dimension value, a trailing Total
  /// column, a trailing Total row) instead of the flat normalized rows.
  /// This is the primary reason a matrix report exists at all per the
  /// original requirement ("Matrix Report — variable columns — mostly for
  /// Excel download") — flat-row export would defeat the point. Reuses
  /// the exact same pivot arithmetic as SakalReportMatrixTable
  /// (report_matrix_pivot.dart) so the downloaded file can never disagree
  /// with what's on screen.
  static Future<void> exportMatrix({
    required ReportDefinition definition,
    required List<ReportColumn> columns,
    required List<ReportRow> rows,
    required String numberFormat,
  }) async {
    final pivotCols = findMatrixPivotColumns(columns);
    if (pivotCols == null) return;
    final pivot = pivotReportRows(
      rowGroupCols: pivotCols.rowGroupCols,
      dimensionCol: pivotCols.dimensionCol,
      measureCol: pivotCols.measureCol,
      rows: rows,
    );

    final workbook = xls.Excel.createExcel();
    final sheetName = workbook.getDefaultSheet()!;
    final sheet = workbook[sheetName];

    sheet.appendRow([
      ...pivotCols.rowGroupCols.map((c) => xls.TextCellValue(c.label)),
      ...pivot.dimensionValues.map((d) => xls.TextCellValue(d)),
      xls.TextCellValue('Total'),
    ]);

    for (final rowKey in pivot.rowKeysSorted) {
      final values = pivot.rowKeyValues[rowKey]!;
      sheet.appendRow([
        ...values.map((v) => xls.TextCellValue('${v ?? ''}')),
        ...pivot.dimensionValues.map((d) => xls.TextCellValue((pivot.cells['$rowKey||$d'] ?? 0).toStringAsFixed(2))),
        xls.TextCellValue((pivot.rowTotals[rowKey] ?? 0).toStringAsFixed(2)),
      ]);
    }

    sheet.appendRow([
      xls.TextCellValue('Total'),
      ...List.generate(pivotCols.rowGroupCols.length - 1, (_) => xls.TextCellValue('')),
      ...pivot.dimensionValues.map((d) => xls.TextCellValue((pivot.columnTotals[d] ?? 0).toStringAsFixed(2))),
      xls.TextCellValue(pivot.grandTotal.toStringAsFixed(2)),
    ]);

    final bytes = workbook.encode();
    if (bytes == null) return;
    final filename = '${definition.reportKey.toLowerCase()}_${DateTime.now().millisecondsSinceEpoch}.xlsx';
    await _saveWorkbookBytes(bytes, filename, 'Save ${definition.reportName}');
  }

  static String _cellText(ReportColumn c, ReportRow row) {
    final value = row[c.columnKey];
    if (value == null) return '';
    if (c.dataType == 'NUMBER' && value is num) {
      final code = c.currencyCodeColumn != null ? row[c.currencyCodeColumn]?.toString() : null;
      final numText = value.toStringAsFixed(2);
      return code != null ? '$code $numText' : numText;
    }
    return '$value';
  }
}
