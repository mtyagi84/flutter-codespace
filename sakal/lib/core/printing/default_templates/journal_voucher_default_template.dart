import '../print_models.dart';

/// Hardcoded fallback for document_type='JOURNAL_VOUCHER'.
///
/// Split out from the shared voucher_default_template.dart (document_type
/// 'VOUCHER', still used by Payment/Receipt Voucher and Contra Voucher)
/// because JV's own lines table needs separate Debit/Credit columns —
/// changing the shared template's single 'amount' column would have broken
/// those other two screens' printed output, since neither supplies
/// debit/credit keys in its own line data. See
/// journal_voucher_entry_screen.dart's _buildPrintDocument().
///
/// x/y here are ordering/grouping keys for the flowing canvas renderer, not
/// literal coordinates — see pdf_canvas_renderer.dart's class comment.
///
/// Visual design pass (2026-08-19): accent-colored section rules (a `line`
/// element's h/font.colorHex become thickness/color overrides — see
/// pdf_canvas_renderer.dart's line case), a short "sign above the line"
/// rule pair over Prepared/Authorised By, and a rule directly above the
/// totals block to separate it from the line-items table.
const journalVoucherDefaultTemplate = PrintTemplate(
  documentType: 'JOURNAL_VOUCHER',
  templateName: 'Default',
  paperProfile: PaperProfile.a4,
  isDefault: true,
  elements: [
    // Letterhead: the logo sits ALONE on its own row (no company_name/title
    // beside it). This is deliberate, not the earlier attempt: putting
    // company_address/company_city on separate rows that only VISUALLY
    // matched company_name's own column via identical flex weights (or
    // even a fixed-width shared column) turned out not to reliably align
    // in the real renderer (real bug, reported live 2026-08-19, THREE
    // times — flex-ratio matching and a fixed-width column both failed to
    // fix it in practice). Putting the logo on its own row removes the
    // dependency entirely: company_name/company_address/company_city all
    // sit at x:1 in their OWN 2-element rows (paired with
    // title/voucher_no/trans_date at x:2) — there is no second row to
    // stay in sync with, so alignment can't drift. The only cost is a
    // small amount of blank space beside the logo at the top — kept small
    // because the logo itself is capped to a compact 0.5in box by
    // pdf_canvas_renderer.dart's image case, regardless of the company's
    // configured print size.
    PrintElement(
      id: 'logo', type: PrintElementType.image, bind: 'company.logo',
      x: 1, y: 1, w: 35,
    ),
    PrintElement(
      id: 'company_name', type: PrintElementType.field, bind: 'company.company_name',
      x: 1, y: 2, w: 130, font: PrintFont(size: 17, bold: true, colorHex: '#1B3A6B'),
    ),
    PrintElement(
      id: 'title', type: PrintElementType.field, bind: 'header.voucher_type_label',
      x: 2, y: 2, w: 90,
      font: PrintFont(size: 17, bold: true, align: PrintAlign.right, colorHex: '#1B3A6B'),
    ),
    PrintElement(
      id: 'company_address', type: PrintElementType.field, bind: 'company.address',
      x: 1, y: 3, w: 130, font: PrintFont(size: 9, colorHex: '#4A5568'),
    ),
    PrintElement(
      id: 'voucher_no', type: PrintElementType.field, bind: 'header.voucher_no', label: 'Voucher No: ',
      x: 2, y: 3, w: 90, font: PrintFont(size: 10, bold: true, align: PrintAlign.right),
    ),
    PrintElement(
      id: 'company_city', type: PrintElementType.field, bind: 'company.city_name',
      x: 1, y: 4, w: 130, font: PrintFont(size: 9, colorHex: '#4A5568'),
    ),
    PrintElement(
      id: 'trans_date', type: PrintElementType.field, bind: 'header.trans_date', label: 'Date: ',
      x: 2, y: 4, w: 90, font: PrintFont(size: 10, align: PrintAlign.right),
    ),
    // Accent rule under the letterhead — thicker + navy, not the default
    // thin grey divider, so the letterhead reads as a distinct block.
    PrintElement(
      id: 'div1', type: PrintElementType.line, x: 1, y: 5, w: 180,
      h: 1.4, font: PrintFont(colorHex: '#1B3A6B'),
    ),
    PrintElement(
      id: 'ref_no', type: PrintElementType.field, bind: 'header.ref_no', label: 'Ref No: ',
      x: 1, y: 6, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'currency_line', type: PrintElementType.field, bind: 'header.currency_line', label: 'Currency: ',
      x: 2, y: 6, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'remarks', type: PrintElementType.field, bind: 'header.remarks', label: 'Remarks: ',
      x: 1, y: 7, w: 180, font: PrintFont(size: 9, colorHex: '#4A5568'),
    ),
    PrintElement(id: 'div2', type: PrintElementType.line, x: 1, y: 8, w: 180),
    PrintElement(
      id: 'lines_table', type: PrintElementType.table, bind: 'lines',
      x: 1, y: 9, w: 180,
      columns: [
        PrintTableColumn(bind: 'particulars', label: 'Particulars', width: 63),
        PrintTableColumn(bind: 'debit', label: 'Debit', width: 33, align: PrintAlign.right, format: PrintDataFormat.currency),
        PrintTableColumn(bind: 'credit', label: 'Credit', width: 33, align: PrintAlign.right, format: PrintDataFormat.currency),
        PrintTableColumn(bind: 'party_amount', label: 'Party Amt', width: 26, align: PrintAlign.right, format: PrintDataFormat.currency),
        PrintTableColumn(bind: 'remarks', label: 'Remarks', width: 25),
      ],
    ),
    // A rule directly above the totals block separates it from the table
    // above — otherwise "Total Debit"/"Total Credit" reads as just two more
    // (unbordered) table-less rows with no visual anchor.
    PrintElement(id: 'div_totals', type: PrintElementType.line, x: 1, y: 9.5, w: 180, h: 0.5),
    // Right-aligned via a wide empty spacer + two narrower value fields
    // stacked as their own rows, same trick as the shared voucher
    // template's totals block, but split into Dr/Cr since a JV's own
    // debit and credit totals are always equal (that's the whole point
    // of double-entry) yet both are worth showing explicitly.
    PrintElement(id: 'total_dr_spacer', type: PrintElementType.text, text: '', x: 1, y: 10, w: 110),
    PrintElement(
      id: 'total_dr', type: PrintElementType.field, bind: 'totals.total_dr_display', label: 'Total Debit: ',
      x: 2, y: 10, w: 70,
      font: PrintFont(size: 12, bold: true, align: PrintAlign.right, colorHex: '#1B3A6B'),
    ),
    PrintElement(id: 'total_cr_spacer', type: PrintElementType.text, text: '', x: 1, y: 11, w: 110),
    PrintElement(
      id: 'total_cr', type: PrintElementType.field, bind: 'totals.total_cr_display', label: 'Total Credit: ',
      x: 2, y: 11, w: 70,
      font: PrintFont(size: 12, bold: true, align: PrintAlign.right, colorHex: '#1B3A6B'),
    ),
    PrintElement(
      id: 'div3', type: PrintElementType.line, x: 1, y: 12, w: 180,
      h: 1.4, font: PrintFont(colorHex: '#1B3A6B'),
    ),
    // Short "sign above the line" rules, one per signature column, sitting
    // directly above the Prepared/Authorised By labels below — a plain rule
    // spanning the whole row's own flex slot inside its Row/Expanded, same
    // mechanism as any other 2-up row.
    PrintElement(id: 'sig_line_1', type: PrintElementType.line, x: 1, y: 12.6, w: 90, h: 0.5),
    PrintElement(id: 'sig_line_2', type: PrintElementType.line, x: 2, y: 12.6, w: 90, h: 0.5),
    PrintElement(
      id: 'prepared_by', type: PrintElementType.field, bind: 'signatures.prepared_by', label: 'Prepared By: ',
      x: 1, y: 13, w: 90, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
    PrintElement(
      id: 'authorised_by', type: PrintElementType.field, bind: 'signatures.authorised_by', label: 'Authorised By: ',
      x: 2, y: 13, w: 90, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
  ],
);
