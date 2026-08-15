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
const journalVoucherDefaultTemplate = PrintTemplate(
  documentType: 'JOURNAL_VOUCHER',
  templateName: 'Default',
  paperProfile: PaperProfile.a4,
  isDefault: true,
  elements: [
    // Letterhead: company block (logo + name + address + city) on the
    // left, document title + voucher no + date on the right — same 3
    // rows so both sides stay vertically aligned. 'spacer_N' elements
    // reserve the logo's own column width (x:1, w:35) on rows 2-3 so
    // company_address/company_city land in the SAME x:2 slot as
    // company_name above them, instead of sitting flush left under the
    // logo (this row-based layout has no true multi-row "column"
    // concept, so a row with no left-hand element renders its lone
    // field starting at the page margin, not indented to match the row
    // above).
    PrintElement(
      id: 'logo', type: PrintElementType.image, bind: 'company.logo',
      x: 1, y: 1, w: 35, h: 20,
    ),
    PrintElement(
      id: 'company_name', type: PrintElementType.field, bind: 'company.company_name',
      x: 2, y: 1, w: 140, font: PrintFont(size: 16, bold: true, colorHex: '#1B3A6B'),
    ),
    PrintElement(
      id: 'title', type: PrintElementType.field, bind: 'header.voucher_type_label',
      x: 3, y: 1, w: 70,
      font: PrintFont(size: 16, bold: true, align: PrintAlign.right, colorHex: '#1B3A6B'),
    ),
    PrintElement(id: 'spacer_2', type: PrintElementType.text, text: '', x: 1, y: 2, w: 35),
    PrintElement(
      id: 'company_address', type: PrintElementType.field, bind: 'company.address',
      x: 2, y: 2, w: 140, font: PrintFont(size: 9),
    ),
    PrintElement(
      id: 'voucher_no', type: PrintElementType.field, bind: 'header.voucher_no', label: 'Voucher No: ',
      x: 3, y: 2, w: 70, font: PrintFont(size: 10, bold: true, align: PrintAlign.right),
    ),
    PrintElement(id: 'spacer_3', type: PrintElementType.text, text: '', x: 1, y: 3, w: 35),
    PrintElement(
      id: 'company_city', type: PrintElementType.field, bind: 'company.city_name',
      x: 2, y: 3, w: 140, font: PrintFont(size: 9),
    ),
    PrintElement(
      id: 'trans_date', type: PrintElementType.field, bind: 'header.trans_date', label: 'Date: ',
      x: 3, y: 3, w: 70, font: PrintFont(size: 10, align: PrintAlign.right),
    ),
    PrintElement(id: 'div1', type: PrintElementType.line, x: 1, y: 4, w: 180),
    PrintElement(
      id: 'ref_no', type: PrintElementType.field, bind: 'header.ref_no', label: 'Ref No: ',
      x: 1, y: 8, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'currency_line', type: PrintElementType.field, bind: 'header.currency_line',
      x: 2, y: 8, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'remarks', type: PrintElementType.field, bind: 'header.remarks', label: 'Remarks: ',
      x: 1, y: 9, w: 180, font: PrintFont(size: 9),
    ),
    PrintElement(id: 'div2', type: PrintElementType.line, x: 1, y: 11, w: 180),
    PrintElement(
      id: 'lines_table', type: PrintElementType.table, bind: 'lines',
      x: 1, y: 12, w: 180,
      columns: [
        PrintTableColumn(bind: 'particulars', label: 'Particulars', width: 65),
        PrintTableColumn(bind: 'debit', label: 'Debit', width: 33, align: PrintAlign.right, format: PrintDataFormat.currency),
        PrintTableColumn(bind: 'credit', label: 'Credit', width: 33, align: PrintAlign.right, format: PrintDataFormat.currency),
        PrintTableColumn(bind: 'party_amount', label: 'Party Amt', width: 24, align: PrintAlign.right),
        PrintTableColumn(bind: 'remarks', label: 'Remarks', width: 25),
      ],
    ),
    // Right-aligned via a wide empty spacer + two narrower value fields
    // stacked as their own rows, same trick as the shared voucher
    // template's totals block, but split into Dr/Cr since a JV's own
    // debit and credit totals are always equal (that's the whole point
    // of double-entry) yet both are worth showing explicitly.
    PrintElement(id: 'total_dr_spacer', type: PrintElementType.text, text: '', x: 1, y: 13, w: 110),
    PrintElement(
      id: 'total_dr', type: PrintElementType.field, bind: 'totals.total_dr_display', label: 'Total Debit: ',
      x: 2, y: 13, w: 70,
      font: PrintFont(size: 12, bold: true, align: PrintAlign.right, colorHex: '#1B3A6B'),
    ),
    PrintElement(id: 'total_cr_spacer', type: PrintElementType.text, text: '', x: 1, y: 14, w: 110),
    PrintElement(
      id: 'total_cr', type: PrintElementType.field, bind: 'totals.total_cr_display', label: 'Total Credit: ',
      x: 2, y: 14, w: 70,
      font: PrintFont(size: 12, bold: true, align: PrintAlign.right, colorHex: '#1B3A6B'),
    ),
    PrintElement(id: 'div3', type: PrintElementType.line, x: 1, y: 15, w: 180),
    PrintElement(
      id: 'prepared_by', type: PrintElementType.field, bind: 'signatures.prepared_by', label: 'Prepared By: ',
      x: 1, y: 16, w: 90, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
    PrintElement(
      id: 'authorised_by', type: PrintElementType.field, bind: 'signatures.authorised_by', label: 'Authorised By: ',
      x: 2, y: 16, w: 90, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
  ],
);
