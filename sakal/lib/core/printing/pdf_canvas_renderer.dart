import 'dart:convert';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'print_models.dart';

/// Renders an A4/LETTER template — elements sit at absolute (x, y) in
/// millimetres, exactly as authored in the template. Used for formal
/// documents (Purchase Order, Voucher, future Invoice/Quotation). See
/// pdf_flow_renderer.dart for the receipt-profile counterpart.
class PdfCanvasRenderer {
  static pw.Document render(PrintTemplate template, Map<String, dynamic> document) {
    final pageFormat = template.paperProfile == PaperProfile.letter
        ? PdfPageFormat.letter
        : PdfPageFormat.a4;

    final doc = pw.Document();
    doc.addPage(pw.Page(
      pageFormat: pageFormat,
      margin: pw.EdgeInsets.zero,
      build: (context) => pw.Stack(
        children: [
          for (final el in template.elements)
            if (el.showWhen == null || el.showWhen!.evaluate(document))
              _place(el, document),
        ],
      ),
    ));
    return doc;
  }

  static pw.Widget _place(PrintElement el, Map<String, dynamic> document) {
    if (el.type == PrintElementType.watermark) {
      return pw.Positioned.fill(
        child: pw.Center(
          child: pw.Transform.rotate(
            angle: 0.5,
            child: pw.Text(
              el.text ?? '',
              style: pw.TextStyle(
                fontSize: 56,
                color: PdfColors.red200,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
          ),
        ),
      );
    }
    // pw.Positioned has no width/height parameters (unlike Flutter's) — size
    // the content with a SizedBox instead and only position its top-left.
    return pw.Positioned(
      left: el.x * PdfPageFormat.mm,
      top:  el.y * PdfPageFormat.mm,
      child: pw.SizedBox(
        width:  el.w * PdfPageFormat.mm,
        height: el.h * PdfPageFormat.mm,
        child:  _content(el, document),
      ),
    );
  }

  static pw.Widget _content(PrintElement el, Map<String, dynamic> document) {
    switch (el.type) {
      case PrintElementType.text:
        return pw.Text(el.text ?? '', style: _style(el.font), textAlign: _align(el.font.align));

      case PrintElementType.field:
        final value = resolveScalar(document, el.bind ?? '');
        final text  = '${el.label ?? ''}${value ?? ''}';
        return pw.Text(text, style: _style(el.font), textAlign: _align(el.font.align));

      case PrintElementType.image:
        final b64 = resolveScalar(document, el.bind ?? '') as String?;
        if (b64 == null || b64.isEmpty) return pw.SizedBox();
        try {
          return pw.Image(pw.MemoryImage(base64Decode(b64)), fit: pw.BoxFit.contain);
        } catch (_) {
          return pw.SizedBox();
        }

      case PrintElementType.line:
        return pw.Divider(thickness: 0.75, color: PdfColors.grey600);

      case PrintElementType.rect:
        return pw.Container(decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey600)));

      case PrintElementType.barcode:
        final value = resolveScalar(document, el.bind ?? '')?.toString() ?? '';
        return pw.BarcodeWidget(
          barcode: el.barcodeFormat == PrintBarcodeFormat.qr ? pw.Barcode.qrCode() : pw.Barcode.code128(),
          data: value,
        );

      case PrintElementType.table:
        return _table(el, document);

      case PrintElementType.watermark:
        return pw.SizedBox(); // handled in _place
    }
  }

  static pw.Widget _table(PrintElement el, Map<String, dynamic> document) {
    final rows = (resolveScalar(document, el.bind ?? '') as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();

    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
      columnWidths: {
        for (var i = 0; i < el.columns.length; i++)
          i: pw.FixedColumnWidth(el.columns[i].width * PdfPageFormat.mm),
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
        for (final row in rows)
          pw.TableRow(
            children: el.columns.map((c) => pw.Padding(
              padding: const pw.EdgeInsets.all(4),
              child: pw.Text(formatPrintValue(row[c.bind], c.format),
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
