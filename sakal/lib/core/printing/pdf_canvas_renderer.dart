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
  static pw.Document render(
    PrintTemplate template,
    Map<String, dynamic> document, {
    String? printedByName,
    DateTime? printedOn,
  }) {
    final pageFormat = template.paperProfile == PaperProfile.letter
        ? PdfPageFormat.letter
        : PdfPageFormat.a4;

    final visible = template.elements
        .where((el) => el.showWhen == null || el.showWhen!.evaluate(document))
        // An image element (in practice, always the logo) with no bound
        // value must not reserve its row's flex slot — otherwise a company
        // with no logo still gets a blank gap where it would have sat, and
        // the sibling element (company name/address) doesn't actually
        // start from the left margin the way it visually should. See
        // ric_companies.logo_width_inch/logo_height_inch (migration 125).
        .where((el) => el.type != PrintElementType.image || _hasImageValue(el, document))
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
          // Extra breathing room after a FULL-WIDTH single-line divider — a
          // plain 4pt gap everywhere reads cramped right after a section
          // separator. A short line (or a row of several short lines, e.g.
          // a per-column "sign above the line" pair) is deliberately meant
          // to sit close to whatever follows it, so it keeps the tighter
          // default gap instead.
          pw.SizedBox(
            height: rowsByY[y]!.length == 1 &&
                    rowsByY[y]!.first.type == PrintElementType.line &&
                    rowsByY[y]!.first.w >= 170
                ? 8 : 4,
          ),
        ],
      ],
      footer: (context) => _footer(context, printedByName, printedOn),
    ));
    return doc;
  }

  // Printed By / Printed On / Page N of M — shared across every document
  // type via this one renderer, so no per-template element is needed.
  // printedByName/printedOn are optional (null on an offline/manager-review
  // print path that hasn't resolved the current user yet) — in that case
  // only the page-number segment renders.
  static pw.Widget _footer(pw.Context context, String? printedByName, DateTime? printedOn) {
    final parts = <String>[
      if (printedByName != null && printedByName.isNotEmpty) 'Printed By: $printedByName',
      if (printedOn != null) 'Printed On: ${_formatDateTime(printedOn)}',
      'Page ${context.pageNumber} of ${context.pagesCount}',
    ];
    return pw.Container(
      width: double.infinity,
      alignment: pw.Alignment.centerRight,
      margin: const pw.EdgeInsets.only(top: 6),
      padding: const pw.EdgeInsets.only(top: 4),
      decoration: const pw.BoxDecoration(
        border: pw.Border(top: pw.BorderSide(color: PdfColors.grey400, width: 0.5)),
      ),
      child: pw.Text(
        parts.join('   |   '),
        style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
      ),
    );
  }

  static String _formatDateTime(DateTime dt) {
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$d-$m-${dt.year} $h:$min';
  }

  // Matches pdf_canvas_renderer's own letterhead logo cap (maxLetterheadLogoIn
  // = 0.5in ≈ 36pt, see the image case below) — used to give the logo's own
  // column a FIXED width instead of a flex share, so it's pixel-identical
  // across every row that reserves it, not just proportionally similar.
  static const _logoColumnWidthPt = 36.0;

  static pw.Widget _buildRow(List<PrintElement> rowElements, Map<String, dynamic> document) {
    if (rowElements.length == 1) return _content(rowElements.first, document);
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < rowElements.length; i++) ...[
          if (i > 0) pw.SizedBox(width: 12),
          if (_isLogoColumn(rowElements[i]))
            // Fixed width, not flex — guarantees this column lines up
            // exactly with the logo's own row, instead of depending on
            // matching flex ratios across separately-laid-out Row
            // instances (real bug reported live 2026-08-19: company_address
            // wasn't lining up under company_name despite identical `w:`
            // values on both rows).
            pw.SizedBox(width: _logoColumnWidthPt, child: _content(rowElements[i], document))
          else
            pw.Expanded(
              flex: rowElements[i].w.round().clamp(1, 1000),
              child: _content(rowElements[i], document),
            ),
        ],
      ],
    );
  }

  // The logo itself, or an empty-text `spacer_*` element reserving the
  // logo's own column on a row below it (journal_voucher_default_template.
  // dart / voucher_default_template.dart's `spacer_2`/`spacer_3`). The
  // `spacer_` id prefix is deliberately specific — every OTHER template's
  // own empty-text spacer (the unrelated "push total right" trick) is named
  // `totals_spacer_*`/`total_*_spacer` and must keep its existing flex
  // behavior, not get pulled into this fixed-width treatment.
  static bool _isLogoColumn(PrintElement el) =>
      el.type == PrintElementType.image ||
      (el.type == PrintElementType.text && (el.text ?? '').isEmpty && el.id.startsWith('spacer_'));

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
          // Company-level logo_width_inch/logo_height_inch (ric_companies,
          // migration 125) override this element's own w/h — the physical
          // print size of a company's logo is a company-wide setting, not
          // a per-template one, so every document type shares it. Every
          // image element in this codebase is the logo (bind
          // 'company.logo'), so no per-element opt-out is needed.
          final company = document['company'] as Map<String, dynamic>? ?? const {};
          var widthIn  = (company['logo_width_inch']  as num?)?.toDouble() ?? 1.0;
          var heightIn = (company['logo_height_inch'] as num?)?.toDouble() ?? 1.0;
          // Cap the LETTERHEAD's own displayed logo size. A transactional
          // document's letterhead sits the logo beside 2-3 short lines of
          // company name/address/city text — rendering the company's full
          // configured print size (defaults 1x1in) there forces that
          // shared row far taller than the text next to it, wasting
          // vertical space either above or below the text depending on
          // which layout is tried (real bug reported live 2026-08-19,
          // twice, from both directions — logo-beside-text left a gap
          // below the short text, logo-on-its-own-row left a gap beside
          // it at the top). Scaling proportionally down to a compact
          // icon-sized box keeps the logo legible while letting the text
          // beside it — not the logo — dictate the row height.
          const maxLetterheadLogoIn = 0.5;
          if (widthIn > maxLetterheadLogoIn || heightIn > maxLetterheadLogoIn) {
            final scale = maxLetterheadLogoIn / (widthIn > heightIn ? widthIn : heightIn);
            widthIn *= scale;
            heightIn *= scale;
          }
          return pw.SizedBox(
            width: widthIn * 25.4 * PdfPageFormat.mm,
            height: heightIn * 25.4 * PdfPageFormat.mm,
            child: pw.Image(pw.MemoryImage(base64Decode(b64)),
                fit: pw.BoxFit.contain, alignment: pw.Alignment.centerLeft),
          );
        } catch (_) {
          return pw.SizedBox();
        }

      case PrintElementType.line:
        // Default look (thickness 0.75, grey) is preserved for every
        // existing template that doesn't override h/font.colorHex — this
        // element type's own defaults (h: 10, colorHex: '#000000') are
        // deliberately never hit in practice by a plain divider, so reusing
        // them as opt-in thickness/color overrides is backward-compatible:
        // a template only gets a custom-styled rule if it explicitly asks
        // for one (see journal_voucher_default_template.dart's accent
        // dividers) by setting h to something other than the type default.
        return pw.Divider(
          thickness: el.h != 10 ? el.h : 0.75,
          color: el.font.colorHex != '#000000' ? PdfColor.fromHex(el.font.colorHex) : PdfColors.grey600,
        );

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

  static bool _hasImageValue(PrintElement el, Map<String, dynamic> document) {
    final b64 = resolveScalar(document, el.bind ?? '') as String?;
    return b64 != null && b64.isNotEmpty;
  }

  static pw.Widget _table(PrintElement el, Map<String, dynamic> document) {
    final rows = (resolveScalar(document, el.bind ?? '') as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    if (rows.isEmpty) return pw.SizedBox(); // skip an empty table entirely rather than a lone header row

    // Brand navy (#1B3A6B, AppColors.primary) tinted header instead of plain
    // grey — a light tint keeps body text legible while still reading as a
    // deliberate, branded header band rather than a generic grid.
    final headerTint = PdfColor.fromHex('#E8EDF5');
    final headerNavy = PdfColor.fromHex('#1B3A6B');
    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
      columnWidths: {
        for (var i = 0; i < el.columns.length; i++)
          i: pw.FlexColumnWidth(el.columns[i].width),
      },
      children: [
        if (el.showHeader)
          pw.TableRow(
            decoration: pw.BoxDecoration(color: headerTint),
            children: el.columns.map((c) => pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
              child: pw.Text(c.label,
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9, color: headerNavy),
                  textAlign: _align(c.align)),
            )).toList(),
          ),
        for (final entry in rows.asMap().entries)
          pw.TableRow(
            decoration: pw.BoxDecoration(color: entry.key.isOdd ? PdfColors.grey50 : PdfColors.white),
            children: el.columns.map((c) => pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4.5),
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
