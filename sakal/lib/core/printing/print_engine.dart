import 'package:flutter/foundation.dart';
import 'package:printing/printing.dart';
import 'pdf_canvas_renderer.dart';
import 'pdf_flow_renderer.dart';
import 'print_models.dart';

/// Single entry point every screen's Print button calls — picks the canvas
/// or flow renderer based on the template's paper profile, then hands the
/// bytes to the OS print dialog (Web/desktop) or share sheet (mobile),
/// exactly like the bespoke VoucherPdfBuilder did before this engine
/// existed (that class is retired — this replaces it for every doc type).
class PrintEngine {
  static Future<void> printDocument({
    required PrintTemplate template,
    required Map<String, dynamic> document,
    required String filename,
  }) async {
    final doc = template.paperProfile.isReceipt
        ? PdfFlowRenderer.render(template, document)
        : PdfCanvasRenderer.render(template, document);
    final bytes = await doc.save();

    final isMobile = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);
    if (isMobile) {
      await Printing.sharePdf(bytes: bytes, filename: filename);
    } else {
      await Printing.layoutPdf(onLayout: (_) async => bytes, name: filename);
    }
  }
}
