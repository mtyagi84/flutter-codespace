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

    // Real bug found live: kIsWeb is true even when the app is opened in a
    // *mobile browser* (this project is primarily deployed as a Flutter Web
    // build, viewed on phones via the browser, not as a native mobile app)
    // -- the old `!kIsWeb && (Android || iOS)` check could therefore never
    // be true on mobile web, so every mobile print fell into the
    // Printing.layoutPdf() branch, which opens an in-page preview/print
    // overlay with no back navigation on a phone-sized viewport ("PDF
    // appears on the same screen, no way to go back", reported on every
    // print button). Printing.sharePdf() has its own Web implementation --
    // on web it triggers a normal browser file download (or the native
    // share sheet on a real mobile app) instead of an in-app overlay, so
    // route Web there too, not just native Android/iOS. layoutPdf's real
    // OS print dialog is kept only for a genuine native desktop build,
    // where there's an actual print dialog to open.
    final isNativeDesktop = !kIsWeb &&
        defaultTargetPlatform != TargetPlatform.android && defaultTargetPlatform != TargetPlatform.iOS;
    if (isNativeDesktop) {
      await Printing.layoutPdf(onLayout: (_) async => bytes, name: filename);
    } else {
      await Printing.sharePdf(bytes: bytes, filename: filename);
    }
  }
}
