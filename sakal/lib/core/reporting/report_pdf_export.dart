import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'report_export_helpers.dart';
import 'report_models.dart';
import 'report_repository.dart';

/// PDF export for any report — reuses the same bytes ->
/// `Printing.sharePdf()`/`layoutPdf()` dispatch `PrintEngine` already uses
/// (see `lib/core/printing/print_engine.dart`) rather than routing through
/// `PrintTemplate`/`PrintElement`, which is document-layout-centric and
/// too heavy for a report's simple paginated table (title + filter
/// summary + table + page footer).
///
/// v1 note: generation runs synchronously on the UI isolate, not via
/// `compute()`. `max_export_rows` (see ReportRepository.fetchAllForExport)
/// already bounds the work; moving generation to a background isolate
/// with a progress indicator is a safe, self-contained follow-up once a
/// real large export proves it's needed — not attempted here without a
/// local Flutter toolchain to verify the isolate boundary against.
class ReportPdfExport {
  static Future<void> export({
    required ReportDefinition definition,
    required List<ReportColumn> columns,
    required List<ReportRow> rows,
    required Map<String, String> filterSummary,
    ReportRow? totalsRow,
  }) async {
    final doc = pw.Document();
    final visibleColumns = columns.where((c) => c.defaultVisible).toList();

    final dataRows = rows.map((row) {
      if (isExportSubtotalRow(row)) {
        // Position-independent: the synthetic subtotal row only carries a
        // value for its aggregate columns plus the one group-label column
        // (see prepareGroupedExportRows) — whichever visible column that
        // happens to be, not necessarily the first one.
        return visibleColumns.map((c) {
          if (c.aggregateFn != null) return _cellText(c, row);
          final v = row[c.columnKey];
          return v != null ? 'Subtotal: $v' : '';
        }).toList();
      }
      return visibleColumns.map((c) => _cellText(c, row)).toList();
    }).toList();
    if (totalsRow != null) {
      dataRows.add(List.generate(visibleColumns.length, (i) {
        final c = visibleColumns[i];
        if (i == 0) return 'Total';
        if (c.aggregateFn == null) return '';
        return _cellText(c, totalsRow);
      }));
    }

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        header: (context) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(definition.reportName, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          if (filterSummary.isNotEmpty)
            pw.Text(filterSummary.entries.map((e) => '${e.key}: ${e.value}').join('   |   '),
                style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
          pw.SizedBox(height: 8),
        ]),
        footer: (context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text('Page ${context.pageNumber} of ${context.pagesCount}', style: const pw.TextStyle(fontSize: 8)),
        ),
        build: (context) => [
          pw.TableHelper.fromTextArray(
            headers: visibleColumns.map((c) => c.label).toList(),
            data: dataRows,
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9, color: PdfColors.white),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey800),
            cellStyle: const pw.TextStyle(fontSize: 8),
            cellAlignments: {
              for (var i = 0; i < visibleColumns.length; i++)
                i: visibleColumns[i].isNumeric ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
            },
          ),
        ],
      ),
    );

    final bytes = await doc.save();
    final filename = '${definition.reportKey.toLowerCase()}_${DateTime.now().millisecondsSinceEpoch}.pdf';

    // Same platform dispatch as PrintEngine.printDocument — see that
    // file's own comment for why Web must go through sharePdf() too, not
    // just native Android/iOS.
    final isNativeDesktop = !kIsWeb &&
        defaultTargetPlatform != TargetPlatform.android && defaultTargetPlatform != TargetPlatform.iOS;
    if (isNativeDesktop) {
      await Printing.layoutPdf(onLayout: (_) async => bytes, name: filename);
    } else {
      await Printing.sharePdf(bytes: bytes, filename: filename);
    }
  }

  static String _cellText(ReportColumn c, ReportRow row) {
    final value = row[c.columnKey];
    if (value == null) return '—';
    if (c.dataType == 'NUMBER' && value is num) {
      final code = c.currencyCodeColumn != null ? row[c.currencyCodeColumn]?.toString() : null;
      final numText = value.toStringAsFixed(2);
      return code != null ? '$code $numText' : numText;
    }
    return '$value';
  }
}
