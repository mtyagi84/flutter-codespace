import '../print_models.dart';

/// Hardcoded fallback for document_type='VOUCHER', replacing the old
/// bespoke VoucherPdfBuilder. On Account and Against Bill rows are
/// normalized into one common {particulars, amount, party_amount, remarks}
/// shape by the screen's print handler (see
/// FinanceVoucherEntryScreen._buildPrintDocument()) so a single table
/// element can serve both modes — a deliberate v1 simplification; a richer
/// dual-mode layout (separate bill no/date/balance columns) can be built in
/// the template designer (Phase 2) once it exists.
///
/// x/y here are ordering/grouping keys for the flowing canvas renderer, not
/// literal coordinates — see pdf_canvas_renderer.dart's class comment and
/// purchase_order_default_template.dart, which follows the same pattern.
///
/// header.total_display and lines[].party_amount are already pre-formatted
/// display strings built by the screen (e.g. "1,234.56 USD") — their
/// elements deliberately use the default text format, not currency
/// (applying currency formatting to an already-suffixed string would break
/// it, since it isn't a bare number).
const voucherDefaultTemplate = PrintTemplate(
  documentType: 'VOUCHER',
  templateName: 'Default',
  paperProfile: PaperProfile.a4,
  isDefault: true,
  elements: [
    // Letterhead: logo beside a TIGHT multi-line company-info block, title
    // beside an equally tight voucher-info block — same 'block' element
    // approach as journal_voucher_default_template.dart (see that file's
    // comment for why: three earlier attempts at keeping company_address/
    // company_city aligned under company_name via matching row structure
    // all still drifted out of alignment in the real renderer). A block's
    // lines render as one pw.Column, so line 2 sits directly under line 1
    // by construction — no second row's width/flex to stay in sync with.
    PrintElement(
      id: 'logo', type: PrintElementType.image, bind: 'company.logo',
      x: 1, y: 1, w: 35,
    ),
    PrintElement(
      id: 'company_block', type: PrintElementType.block,
      x: 2, y: 1, w: 130,
      lines: [
        PrintElement(id: 'company_name', type: PrintElementType.field, bind: 'company.company_name',
            font: PrintFont(size: 16, bold: true, colorHex: '#1B3A6B')),
        PrintElement(id: 'company_address', type: PrintElementType.field, bind: 'company.address',
            font: PrintFont(size: 9, colorHex: '#4A5568')),
        PrintElement(id: 'company_city', type: PrintElementType.field, bind: 'company.city_name',
            font: PrintFont(size: 9, colorHex: '#4A5568')),
      ],
    ),
    PrintElement(
      id: 'title_block', type: PrintElementType.block,
      x: 3, y: 1, w: 90, font: PrintFont(align: PrintAlign.right),
      lines: [
        PrintElement(id: 'title', type: PrintElementType.field, bind: 'header.voucher_type_label',
            font: PrintFont(size: 16, bold: true, align: PrintAlign.right, colorHex: '#1B3A6B')),
        PrintElement(id: 'voucher_no', type: PrintElementType.field, bind: 'header.voucher_no', label: 'Voucher No: ',
            font: PrintFont(size: 10, bold: true, align: PrintAlign.right)),
        PrintElement(id: 'trans_date', type: PrintElementType.field, bind: 'header.trans_date', label: 'Date: ',
            font: PrintFont(size: 10, align: PrintAlign.right)),
      ],
    ),
    // Accent rule under the letterhead — thicker + navy, not the default
    // thin grey divider, so the letterhead reads as a distinct block.
    PrintElement(
      id: 'div1', type: PrintElementType.line, x: 1, y: 2, w: 180,
      h: 1.4, font: PrintFont(colorHex: '#1B3A6B'),
    ),
    PrintElement(
      id: 'cash_bank_account', type: PrintElementType.field, bind: 'header.cash_bank_account', label: 'Account: ',
      x: 1, y: 3, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'payment_mode', type: PrintElementType.field, bind: 'header.payment_mode', label: 'Payment Mode: ',
      x: 2, y: 3, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'ref_no', type: PrintElementType.field, bind: 'header.ref_no', label: 'Ref No: ',
      x: 1, y: 4, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'currency_line', type: PrintElementType.field, bind: 'header.currency_line', label: 'Currency: ',
      x: 2, y: 4, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'remarks', type: PrintElementType.field, bind: 'header.remarks', label: 'Remarks: ',
      x: 1, y: 5, w: 180, font: PrintFont(size: 9, colorHex: '#4A5568'),
    ),
    // Against Bill only — same "Party: X" line the old builder showed above
    // the bill table. is_on_account_str is a string ('true'/'false') since
    // PrintCondition compares against a string value.
    PrintElement(
      id: 'party_name', type: PrintElementType.field, bind: 'header.party_name', label: 'Party: ',
      x: 1, y: 6, w: 180, font: PrintFont(size: 10, bold: true),
      showWhen: PrintCondition(field: 'header.is_on_account_str', equals: 'false'),
    ),
    PrintElement(id: 'div2', type: PrintElementType.line, x: 1, y: 7, w: 180),
    PrintElement(
      id: 'lines_table', type: PrintElementType.table, bind: 'lines',
      x: 1, y: 8, w: 180,
      columns: [
        PrintTableColumn(bind: 'particulars', label: 'Particulars', width: 70),
        PrintTableColumn(bind: 'amount', label: 'Amount', width: 40, align: PrintAlign.right, format: PrintDataFormat.currency),
        PrintTableColumn(bind: 'party_amount', label: 'Party Amt', width: 35, align: PrintAlign.right),
        PrintTableColumn(bind: 'remarks', label: 'Remarks', width: 35),
      ],
    ),
    // A rule directly above the total block separates it from the table
    // above — otherwise "Total" reads as just one more (unbordered)
    // table-less row with no visual anchor.
    PrintElement(id: 'div_total', type: PrintElementType.line, x: 1, y: 11.5, w: 180, h: 0.5),
    // Right-aligned via a wide empty spacer + a narrower value field, same
    // trick as the PO template's totals block.
    PrintElement(id: 'total_spacer', type: PrintElementType.text, text: '', x: 1, y: 12, w: 110),
    PrintElement(
      id: 'total', type: PrintElementType.field, bind: 'totals.total_display', label: 'Total: ',
      x: 2, y: 12, w: 70,
      font: PrintFont(size: 13, bold: true, align: PrintAlign.right, colorHex: '#1B3A6B'),
    ),
    PrintElement(
      id: 'div3', type: PrintElementType.line, x: 1, y: 13, w: 180,
      h: 1.4, font: PrintFont(colorHex: '#1B3A6B'),
    ),
    // Short "sign above the line" rules, one per signature column, sitting
    // directly above the Prepared/Authorised By labels below.
    PrintElement(id: 'sig_line_1', type: PrintElementType.line, x: 1, y: 13.6, w: 80, h: 0.5),
    PrintElement(id: 'sig_line_2', type: PrintElementType.line, x: 2, y: 13.6, w: 80, h: 0.5),
    PrintElement(
      id: 'prepared_by', type: PrintElementType.field, bind: 'signatures.prepared_by', label: 'Prepared By: ',
      x: 1, y: 14, w: 80, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
    PrintElement(
      id: 'authorised_by', type: PrintElementType.field, bind: 'signatures.authorised_by', label: 'Authorised By: ',
      x: 2, y: 14, w: 80, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
  ],
);
