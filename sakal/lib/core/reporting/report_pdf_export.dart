import 'dart:convert';
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
/// too heavy for a report's simple paginated table.
///
/// Header/footer follow a standard report letterhead (user-specified):
/// left = company logo, falling back to company name + address when no
/// logo is set (`ric_companies.logo`, base64 — same column/decode
/// (`pw.MemoryImage(base64Decode(...))`) every other document's print
/// template already uses, via `companyDetailsProvider`); right = report
/// heading + applied filters (covers "at least Period" — actually every
/// applied filter, not just date range, since ReportFilterBar's labels
/// already describe themselves). Footer: Printed By / Printed On (left,
/// genuinely new — no prior "who generated this printout" concept
/// existed anywhere in the print engine) / Page X of Y (right).
///
/// v1 note: generation runs synchronously on the UI isolate, not via
/// `compute()`. `max_export_rows` (see ReportRepository.fetchAllForExport)
/// already bounds the work; moving generation to a background isolate
/// with a progress indicator is a safe, self-contained follow-up once a
/// real large export proves it's needed — not attempted here without a
/// local Flutter toolchain to verify the isolate boundary against.
class ReportPdfExport {
  // Brand navy (AppColors.primary, #1B3A6B) — same accent color the
  // transaction-document Print Engine uses for its own letterhead/table
  // styling (pdf_canvas_renderer.dart), applied here so every PDF in the
  // app (report or document) reads as one consistent design.
  static final _navy = PdfColor.fromHex('#1B3A6B');

  static Future<void> export({
    required ReportDefinition definition,
    required List<ReportColumn> columns,
    required List<ReportRow> rows,
    required Map<String, String> filterSummary,
    ReportRow? totalsRow,
    required Map<String, dynamic> company,
    required String printedByName,
    required DateTime printedOn,
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

    // Dynamic orientation: sum the same default_width values the on-screen
    // grid seeds its columns with (a pixel-ish proxy, not exact PDF points,
    // but a reasonable signal for "how wide is this table") — a handful of
    // narrow columns fits portrait fine; most reports with 6+ columns need
    // landscape. 700 is a conservative cutover (roughly 4-5 typical columns).
    final totalColumnWidth = visibleColumns.fold<double>(0, (sum, c) => sum + (c.defaultWidth ?? 140));
    final pageFormat = totalColumnWidth <= 700 ? PdfPageFormat.a4 : PdfPageFormat.a4.landscape;

    doc.addPage(
      pw.MultiPage(
        pageFormat: pageFormat,
        header: (context) => _buildHeader(company, definition.reportName, filterSummary, context.pageNumber),
        footer: (context) => _buildFooter(context, printedByName, printedOn),
        build: (context) => [
          if (rows.isEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 24),
              child: pw.Text('No records found for the selected filters.',
                  style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
            )
          else
            pw.TableHelper.fromTextArray(
              headers: visibleColumns.map((c) => c.label).toList(),
              data: dataRows,
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9, color: PdfColors.white),
              // Brand navy, matching the transaction-document Print Engine's
              // own table header tint (pdf_canvas_renderer.dart) — was
              // generic blueGrey800 before this polish pass.
              headerDecoration: pw.BoxDecoration(color: _navy),
              cellStyle: const pw.TextStyle(fontSize: 8),
              // Proportional to each column's own on-screen default_width,
              // so the printed table's column ratios roughly match what the
              // user sees on the report screen instead of the library's own
              // even/content-based auto-sizing.
              columnWidths: {
                for (var i = 0; i < visibleColumns.length; i++)
                  i: pw.FlexColumnWidth(visibleColumns[i].defaultWidth ?? 140),
              },
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

  static pw.Widget _buildHeader(
      Map<String, dynamic> company, String reportName, Map<String, String> filterSummary, int pageNumber) {
    pw.MemoryImage? logo;
    final logoB64 = company['logo'] as String?;
    if (logoB64 != null && logoB64.isNotEmpty) {
      try {
        logo = pw.MemoryImage(base64Decode(logoB64));
      } catch (_) {
        logo = null; // malformed/corrupt logo data — fall back to name+address, never crash the export
      }
    }

    // Logo AND company name/address print together (logo left, details to
    // its right) whenever a logo is set — never one replacing the other.
    // With no logo, details start from the leftmost edge (no reserved gap).
    // Logo print size is a company-wide setting (ric_companies.
    // logo_width_inch/logo_height_inch, migration 125), the same one the
    // document Print Engine's canvas renderer reads — not a size local to
    // this report header.
    final detailsColumn = pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Text('${company['company_name'] ?? ''}',
          style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: _navy)),
      if ('${company['address'] ?? ''}'.isNotEmpty)
        pw.Text('${company['address']}', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
      if ('${company['city_name'] ?? ''}'.isNotEmpty)
        pw.Text('${company['city_name']}', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
    ]);

    pw.Widget leftBlock = detailsColumn;
    if (logo != null) {
      final widthIn = (company['logo_width_inch'] as num?)?.toDouble() ?? 1.0;
      final heightIn = (company['logo_height_inch'] as num?)?.toDouble() ?? 1.0;
      leftBlock = pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
        pw.SizedBox(
          width: widthIn * 25.4 * PdfPageFormat.mm,
          height: heightIn * 25.4 * PdfPageFormat.mm,
          child: pw.Image(logo, fit: pw.BoxFit.contain, alignment: pw.Alignment.centerLeft),
        ),
        pw.SizedBox(width: 10),
        detailsColumn,
      ]);
    }

    final rightBlock = pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
      pw.Text(reportName, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, color: _navy)),
      // Filter/parameter line only on page 1 — saves space on longer
      // reports; the company block + report heading still repeat on
      // every page (a normal letterhead), just not the parameter list.
      if (pageNumber == 1 && filterSummary.isNotEmpty)
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 3),
          child: pw.Text(
            filterSummary.entries.map((e) => '${e.key}: ${e.value}').join('   |   '),
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
            textAlign: pw.TextAlign.right,
          ),
        ),
    ]);

    return pw.Column(children: [
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(child: leftBlock),
        pw.Expanded(child: pw.Align(alignment: pw.Alignment.topRight, child: rightBlock)),
      ]),
      pw.SizedBox(height: 6),
      // Thicker navy accent rule, matching the transaction-document Print
      // Engine's own letterhead divider (pdf_canvas_renderer.dart) — was a
      // thin plain grey line before this polish pass.
      pw.Divider(thickness: 1.4, color: _navy),
      pw.SizedBox(height: 6),
    ]);
  }

  static pw.Widget _buildFooter(pw.Context context, String printedByName, DateTime printedOn) => pw.Column(children: [
        pw.Divider(thickness: 0.5, color: PdfColors.grey400),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text('Printed By: $printedByName   |   Printed On: ${_fmtDateTime(printedOn)}',
              style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700)),
          pw.Text('Page ${context.pageNumber} of ${context.pagesCount}', style: const pw.TextStyle(fontSize: 8)),
        ]),
      ]);

  static String _fmtDateTime(DateTime dt) {
    final d = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
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
