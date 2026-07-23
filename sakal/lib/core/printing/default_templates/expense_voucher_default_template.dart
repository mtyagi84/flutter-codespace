import '../print_models.dart';

/// Hardcoded fallback used whenever a company has no active
/// ric_print_templates row for document_type='EXPENSE_VOUCHER'. Field
/// bindings match the document map built by ExpenseVoucherEntryScreen's
/// Print handler — see that screen's `_buildPrintDocument()`.
const expenseVoucherDefaultTemplate = PrintTemplate(
  documentType: 'EXPENSE_VOUCHER',
  templateName: 'Default',
  paperProfile: PaperProfile.a4,
  isDefault: true,
  elements: [
    PrintElement(
      id: 'logo', type: PrintElementType.image, bind: 'company.logo',
      x: 1, y: 1, w: 35, h: 20,
    ),
    PrintElement(
      id: 'company_name', type: PrintElementType.field, bind: 'company.company_name',
      x: 2, y: 1, w: 140, font: PrintFont(size: 16, bold: true, colorHex: '#1B3A6B'),
    ),
    PrintElement(
      id: 'company_address', type: PrintElementType.field, bind: 'company.address',
      x: 1, y: 2, w: 180, font: PrintFont(size: 9),
    ),
    PrintElement(
      id: 'company_city', type: PrintElementType.field, bind: 'company.city_name',
      x: 1, y: 3, w: 180, font: PrintFont(size: 9),
    ),
    PrintElement(id: 'div1', type: PrintElementType.line, x: 1, y: 4, w: 180),
    PrintElement(
      id: 'title', type: PrintElementType.text, text: 'EXPENSE VOUCHER',
      x: 1, y: 5, w: 180,
      font: PrintFont(size: 18, bold: true, align: PrintAlign.center, colorHex: '#1B3A6B'),
    ),
    PrintElement(
      id: 'draft_watermark', type: PrintElementType.watermark,
      text: 'DRAFT — NOT APPROVED',
      x: 1, y: 6, w: 180,
      showWhen: PrintCondition(field: 'header.status', notEquals: 'APPROVED'),
    ),
    PrintElement(
      id: 'voucher_no', type: PrintElementType.field, bind: 'header.voucher_no', label: 'Voucher No: ',
      x: 1, y: 7, w: 90, font: PrintFont(size: 10, bold: true),
    ),
    PrintElement(
      id: 'trans_date', type: PrintElementType.field, bind: 'header.trans_date', label: 'Date: ',
      x: 2, y: 7, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'supplier', type: PrintElementType.field, bind: 'header.supplier_name', label: 'Supplier: ',
      x: 1, y: 8, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'currency', type: PrintElementType.field, bind: 'header.currency_code', label: 'Currency: ',
      x: 2, y: 8, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'bill_no', type: PrintElementType.field, bind: 'header.bill_no', label: 'Bill No: ',
      x: 1, y: 9, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'bill_date', type: PrintElementType.field, bind: 'header.bill_date', label: 'Bill Date: ',
      x: 2, y: 9, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(id: 'div2', type: PrintElementType.line, x: 1, y: 10, w: 180),
    PrintElement(
      id: 'lines_table', type: PrintElementType.table, bind: 'lines',
      x: 1, y: 11, w: 180,
      columns: [
        PrintTableColumn(bind: 'account_name', label: 'Expense Account', width: 70),
        PrintTableColumn(bind: 'amount', label: 'Amount', width: 35, align: PrintAlign.right, format: PrintDataFormat.currency),
        PrintTableColumn(bind: 'tax_group_name', label: 'Tax Group', width: 40),
        PrintTableColumn(bind: 'remarks', label: 'Remarks', width: 35),
      ],
    ),
    PrintElement(
      id: 'total_expense', type: PrintElementType.field, bind: 'totals.total_expense_display', label: 'Total Expense: ',
      x: 1, y: 12, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'net_payable', type: PrintElementType.field, bind: 'totals.net_payable_display', label: 'Net Payable to Supplier: ',
      x: 2, y: 12, w: 90, font: PrintFont(size: 11, bold: true),
    ),
    PrintElement(
      id: 'remarks', type: PrintElementType.field, bind: 'header.remarks', label: 'Remarks: ',
      x: 1, y: 13, w: 180, font: PrintFont(size: 9),
    ),
    PrintElement(id: 'div3', type: PrintElementType.line, x: 1, y: 14, w: 180),
    PrintElement(
      id: 'prepared_by', type: PrintElementType.field, bind: 'signatures.prepared_by', label: 'Prepared By: ',
      x: 1, y: 15, w: 90, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
    PrintElement(
      id: 'authorised_by', type: PrintElementType.field, bind: 'signatures.authorised_by', label: 'Authorised Signatory: ',
      x: 2, y: 15, w: 90, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
  ],
);
