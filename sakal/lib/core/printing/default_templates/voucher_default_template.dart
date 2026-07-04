import '../print_models.dart';

/// Hardcoded fallback for document_type='VOUCHER', replacing the old
/// bespoke VoucherPdfBuilder. On Account and Against Bill rows are
/// normalized into one common {particulars, amount, party_amount, remarks}
/// shape by the screen's print handler (see
/// FinanceVoucherEntryScreen._buildPrintDocument()) so a single table
/// element can serve both modes — a deliberate v1 simplification; a richer
/// dual-mode layout (separate bill no/date/balance columns) can be built in
/// the template designer (Phase 2) once it exists.
final voucherDefaultTemplate = PrintTemplate(
  documentType: 'VOUCHER',
  templateName: 'Default',
  paperProfile: PaperProfile.a4,
  isDefault: true,
  elements: [
    PrintElement(
      id: 'logo', type: PrintElementType.image, bind: 'company.logo',
      x: 15, y: 15, w: 35, h: 20,
    ),
    PrintElement(
      id: 'company_name', type: PrintElementType.field, bind: 'company.company_name',
      x: 55, y: 15, w: 140, h: 7, font: const PrintFont(size: 14, bold: true),
    ),
    PrintElement(
      id: 'company_address', type: PrintElementType.field, bind: 'company.address',
      x: 55, y: 22, w: 140, h: 6, font: const PrintFont(size: 9),
    ),
    PrintElement(
      id: 'company_city', type: PrintElementType.field, bind: 'company.city_name',
      x: 55, y: 28, w: 140, h: 6, font: const PrintFont(size: 9),
    ),
    PrintElement(id: 'div1', type: PrintElementType.line, x: 15, y: 38, w: 180, h: 1),
    PrintElement(
      id: 'title', type: PrintElementType.field, bind: 'header.voucher_type_label',
      x: 15, y: 42, w: 180, h: 10,
      font: const PrintFont(size: 16, bold: true, align: PrintAlign.center),
    ),
    PrintElement(
      id: 'voucher_no', type: PrintElementType.field, bind: 'header.voucher_no', label: 'Voucher No: ',
      x: 15, y: 56, w: 90, h: 6, font: const PrintFont(size: 10, bold: true),
    ),
    PrintElement(
      id: 'trans_date', type: PrintElementType.field, bind: 'header.trans_date', label: 'Date: ',
      x: 110, y: 56, w: 85, h: 6, font: const PrintFont(size: 10),
    ),
    PrintElement(
      id: 'cash_bank_account', type: PrintElementType.field, bind: 'header.cash_bank_account', label: 'Account: ',
      x: 15, y: 63, w: 90, h: 6, font: const PrintFont(size: 10),
    ),
    PrintElement(
      id: 'payment_mode', type: PrintElementType.field, bind: 'header.payment_mode', label: 'Payment Mode: ',
      x: 110, y: 63, w: 85, h: 6, font: const PrintFont(size: 10),
    ),
    PrintElement(
      id: 'ref_no', type: PrintElementType.field, bind: 'header.ref_no', label: 'Ref No: ',
      x: 15, y: 70, w: 90, h: 6, font: const PrintFont(size: 10),
    ),
    PrintElement(
      id: 'currency_line', type: PrintElementType.field, bind: 'header.currency_line',
      x: 110, y: 70, w: 85, h: 6, font: const PrintFont(size: 10),
    ),
    PrintElement(
      id: 'remarks', type: PrintElementType.field, bind: 'header.remarks', label: 'Remarks: ',
      x: 15, y: 77, w: 180, h: 6, font: const PrintFont(size: 9),
    ),
    PrintElement(id: 'div2', type: PrintElementType.line, x: 15, y: 85, w: 180, h: 1),
    PrintElement(
      id: 'lines_table', type: PrintElementType.table, bind: 'lines',
      x: 15, y: 89, w: 180, h: 100,
      columns: const [
        PrintTableColumn(bind: 'particulars', label: 'Particulars', width: 70),
        PrintTableColumn(bind: 'amount', label: 'Amount', width: 40, align: PrintAlign.right, format: PrintDataFormat.currency),
        PrintTableColumn(bind: 'party_amount', label: 'Party Amt', width: 35, align: PrintAlign.right),
        PrintTableColumn(bind: 'remarks', label: 'Remarks', width: 35),
      ],
    ),
    PrintElement(
      id: 'total', type: PrintElementType.field, bind: 'totals.total_display', label: 'Total: ',
      x: 115, y: 195, w: 80, h: 8,
      font: const PrintFont(size: 12, bold: true, align: PrintAlign.right),
    ),
    PrintElement(id: 'div3', type: PrintElementType.line, x: 15, y: 230, w: 180, h: 1),
    PrintElement(
      id: 'prepared_by', type: PrintElementType.field, bind: 'signatures.prepared_by', label: 'Prepared By: ',
      x: 15, y: 235, w: 80, h: 6, font: const PrintFont(size: 9, align: PrintAlign.center),
    ),
    PrintElement(
      id: 'authorised_by', type: PrintElementType.field, bind: 'signatures.authorised_by', label: 'Authorised By: ',
      x: 115, y: 235, w: 80, h: 6, font: const PrintFont(size: 9, align: PrintAlign.center),
    ),
  ],
);
