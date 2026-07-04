import 'dart:convert';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'print_models.dart';

/// Renders an A4/LETTER template as a FLOWING document, not a fixed-pixel
/// canvas. A print template for a business document can't place line-item
/// content at fixed coordinates — a Purchase Order might have 1 line or 50
/// — so a hardcoded box height either wastes space (few lines) or overflows
/// (many lines). Instead: elements that share the same `y` value render
/// side by side in one row (e.g. "PO No" + "Date" on one line); different
/// `y` values become separate rows, stacked in ascending `y` order. `w`
/// becomes each element's relative flex weight within its row, not an
/// absolute width in mm. `y`/`w` are therefore ordering/grouping keys here,
/// not literal coordinates — see the class comment on PrintElement in
/// print_models.dart.
///
/// Uses pw.MultiPage (not pw.Page) so content that genuinely exceeds one
/// page continues onto a real page 2 instead of silently clipping.
class PdfCanvasRenderer {
  static pw.Document render(PrintTemplate template, Map<String, dynamic> document) {
    final pageFormat = template.paperProfile == PaperProfile.letter
        ? PdfPageFormat.letter
        : PdfPageFormat.a4;

    final visible = template.elements
        .where((el) => el.showWhen == null || el.showWhen!.evaluate(document))
        .toList();

    final rowsByY = <double, List<PrintElement>>{};
    for (final el in visible) {
      rowsByY.putIfAbsent(el.y, () => []).add(el);
    }
    final sortedYs = rowsByY.keys.toList()..sort();

    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: pageFormat,
      margin: const pw.EdgeInsets.all(15 * PdfPageFormat.mm),
      build: (context) => [
        for (final y in sortedYs) ...[
          _buildRow(rowsByY[y]!..sort((a, b) => a.x.compareTo(b.x)), document),
          pw.SizedBox(height: 4),
        ],
      ],
    ));
    return doc;
  }

  static pw.Widget _buildRow(List<PrintElement> rowElements, Map<String, dynamic> document) {
    if (rowElements.length == 1) return _content(rowElements.first, document);
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < rowElements.length; i++) ...[
          if (i > 0) pw.SizedBox(width: 12),
          pw.Expanded(
            flex: rowElements[i].w.round().clamp(1, 1000),
            child: _content(rowElements[i], document),
          ),
        ],
      ],
    );
  }

  static pw.Widget _content(PrintElement el, Map<String, dynamic> document) {
    switch (el.type) {
      case PrintElementType.text:
        return pw.Text(el.text ?? '', style: _style(el.font), textAlign: _align(el.font.align));

      case PrintElementType.field:
        final value = resolveScalar(document, el.bind ?? '');
        final text  = '${el.label ?? ''}${formatPrintValue(value, el.format)}';
        return pw.Text(text, style: _style(el.font), textAlign: _align(el.font.align));

      case PrintElementType.image:
        final b64 = resolveScalar(document, el.bind ?? '') as String?;
        if (b64 == null || b64.isEmpty) return pw.SizedBox();
        try {
          return pw.SizedBox(
            height: el.h * PdfPageFormat.mm,
            child: pw.Image(pw.MemoryImage(base64Decode(b64)),
                fit: pw.BoxFit.contain, alignment: pw.Alignment.centerLeft),
          );
        } catch (_) {
          return pw.SizedBox();
        }

      case PrintElementType.line:
        return pw.Divider(thickness: 0.75, color: PdfColors.grey600);

      case PrintElementType.rect:
        return pw.Container(
          height: el.h * PdfPageFormat.mm,
          decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey600)),
        );

      case PrintElementType.barcode:
        final value = resolveScalar(document, el.bind ?? '')?.toString() ?? '';
        return pw.SizedBox(
          height: el.h * PdfPageFormat.mm,
          child: pw.BarcodeWidget(
            barcode: el.barcodeFormat == PrintBarcodeFormat.qr ? pw.Barcode.qrCode() : pw.Barcode.code128(),
            data: value,
          ),
        );

      case PrintElementType.table:
        return _table(el, document);

      case PrintElementType.watermark:
        // A full-width banner in normal flow (its row position is driven by
        // its own `y`, same as everything else) rather than a diagonal
        // overlay — reliable across MultiPage, where a page-spanning
        // overlay would need to be repeated per page.
        return pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.symmetric(vertical: 6),
          decoration: pw.BoxDecoration(
            color: PdfColors.red50,
            border: pw.Border.all(color: PdfColors.red300),
          ),
          child: pw.Center(
            child: pw.Text(el.text ?? '',
                style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: PdfColors.red800)),
          ),
        );
    }
  }

  static pw.Widget _table(PrintElement el, Map<String, dynamic> document) {
    final rows = (resolveScalar(document, el.bind ?? '') as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    if (rows.isEmpty) return pw.SizedBox(); // skip an empty table entirely rather than a lone header row

    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
      columnWidths: {
        for (var i = 0; i < el.columns.length; i++)
          i: pw.FlexColumnWidth(el.columns[i].width),
      },
      children: [
        if (el.showHeader)
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: PdfColors.grey200),
            children: el.columns.map((c) => pw.Padding(
              padding: const pw.EdgeInsets.all(4),
              child: pw.Text(c.label,
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
                  textAlign: _align(c.align)),
            )).toList(),
          ),
        for (final entry in rows.asMap().entries)
          pw.TableRow(
            decoration: pw.BoxDecoration(color: entry.key.isOdd ? PdfColors.grey50 : PdfColors.white),
            children: el.columns.map((c) => pw.Padding(
              padding: const pw.EdgeInsets.all(4),
              child: pw.Text(formatPrintValue(entry.value[c.bind], c.format),
                  style: const pw.TextStyle(fontSize: 9),
                  textAlign: _align(c.align)),
            )).toList(),
          ),
      ],
    );
  }

  static pw.TextStyle _style(PrintFont f) => pw.TextStyle(
    fontSize:   f.size,
    fontWeight: f.bold ? pw.FontWeight.bold : pw.FontWeight.normal,
    fontStyle:  f.italic ? pw.FontStyle.italic : pw.FontStyle.normal,
    color:      PdfColor.fromHex(f.colorHex),
  );

  static pw.TextAlign _align(PrintAlign a) => switch (a) {
    PrintAlign.center => pw.TextAlign.center,
    PrintAlign.right  => pw.TextAlign.right,
    PrintAlign.left   => pw.TextAlign.left,
  };
}
