import 'dart:convert';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'print_models.dart';

/// Renders a RECEIPT_58MM/80MM template — a receipt has no meaningful
/// horizontal space to position things in, so elements simply stack
/// top-to-bottom at full width, in list order. x/y/w/h from the template
/// are ignored here (they only matter for the canvas renderer); alignment
/// comes from each element's font.align instead.
///
/// This renders to a narrow PDF via the same `pdf`/`printing` packages the
/// canvas renderer uses — real ESC/POS thermal-printer byte output is a
/// separate, later concern (ric_print_templates/PrintElement already carry
/// everything needed for that; only the actual printer transport is
/// deferred until a POS screen exists to drive it).
class PdfFlowRenderer {
  static pw.Document render(PrintTemplate template, Map<String, dynamic> document) {
    final pageFormat = PdfPageFormat(
      template.paperProfile.widthMm * PdfPageFormat.mm,
      double.infinity,
      marginAll: 2 * PdfPageFormat.mm,
    );

    final doc = pw.Document();
    doc.addPage(pw.Page(
      pageFormat: pageFormat,
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          for (final el in template.elements)
            if (el.showWhen == null || el.showWhen!.evaluate(document))
              _content(el, document),
        ],
      ),
    ));
    return doc;
  }

  static pw.Widget _content(PrintElement el, Map<String, dynamic> document) {
    switch (el.type) {
      case PrintElementType.text:
        return _line(el.text ?? '', el.font);

      case PrintElementType.field:
        final value = resolveScalar(document, el.bind ?? '');
        return _line('${el.label ?? ''}${formatPrintValue(value, el.format)}', el.font);

      case PrintElementType.image:
        final b64 = resolveScalar(document, el.bind ?? '') as String?;
        if (b64 == null || b64.isEmpty) return pw.SizedBox();
        try {
          return pw.Center(
            child: pw.Image(pw.MemoryImage(base64Decode(b64)), height: 15 * PdfPageFormat.mm),
          );
        } catch (_) {
          return pw.SizedBox();
        }

      case PrintElementType.line:
        return pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 2),
          child: pw.Divider(thickness: 0.5, borderStyle: pw.BorderStyle.dashed),
        );

      case PrintElementType.rect:
        return pw.SizedBox(); // a boxed rectangle doesn't read well in a receipt's flow — skip

      case PrintElementType.barcode:
        final value = resolveScalar(document, el.bind ?? '')?.toString() ?? '';
        return pw.Center(
          child: pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 3),
            child: pw.BarcodeWidget(
              barcode: el.barcodeFormat == PrintBarcodeFormat.qr ? pw.Barcode.qrCode() : pw.Barcode.code128(),
              data: value,
              width: 35 * PdfPageFormat.mm,
              height: 35 * PdfPageFormat.mm,
            ),
          ),
        );

      case PrintElementType.table:
        return _table(el, document);

      case PrintElementType.watermark:
        return pw.SizedBox(); // no watermark concept on a receipt roll
    }
  }

  static pw.Widget _line(String text, PrintFont font) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 0.5),
    child: pw.Text(
      text,
      textAlign: switch (font.align) {
        PrintAlign.center => pw.TextAlign.center,
        PrintAlign.right  => pw.TextAlign.right,
        PrintAlign.left   => pw.TextAlign.left,
      },
      style: pw.TextStyle(
        fontSize:   font.size,
        fontWeight: font.bold ? pw.FontWeight.bold : pw.FontWeight.normal,
      ),
    ),
  );

  /// A receipt has no columns to line up, so each row prints as: the first
  /// bound column on its own line (typically the item name), then the
  /// remaining columns space-between on the next line (typically
  /// qty/rate/amount) — the closest a flowing receipt gets to a grid.
  static pw.Widget _table(PrintElement el, Map<String, dynamic> document) {
    final rows = (resolveScalar(document, el.bind ?? '') as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    if (el.columns.isEmpty || rows.isEmpty) return pw.SizedBox();

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        for (final row in rows)
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 1),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(formatPrintValue(row[el.columns.first.bind], el.columns.first.format),
                    style: const pw.TextStyle(fontSize: 8)),
                if (el.columns.length > 1)
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: el.columns.skip(1).map((c) => pw.Text(
                        formatPrintValue(row[c.bind], c.format),
                        style: const pw.TextStyle(fontSize: 8))).toList(),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
