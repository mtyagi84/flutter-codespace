import '../print_models.dart';

/// Hardcoded fallback used whenever a company has no active
/// ric_print_templates row for document_type='CASH_RECEIPT'. Field
/// bindings match the document map built by CashReceiptEntryScreen's
/// Print handler — see that screen's `_buildPrintDocument()`.
const cashReceiptDefaultTemplate = PrintTemplate(
  documentType: 'CASH_RECEIPT',
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
      id: 'title', type: PrintElementType.text, text: 'CASH RECEIPT',
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
      id: 'receipt_no', type: PrintElementType.field, bind: 'header.receipt_no', label: 'Receipt No: ',
      x: 1, y: 7, w: 90, font: PrintFont(size: 10, bold: true),
    ),
    PrintElement(
      id: 'receipt_date', type: PrintElementType.field, bind: 'header.receipt_date', label: 'Date: ',
      x: 2, y: 7, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'customer', type: PrintElementType.field, bind: 'header.customer_name', label: 'Received From: ',
      x: 1, y: 8, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'location', type: PrintElementType.field, bind: 'header.location_name', label: 'Location: ',
      x: 2, y: 8, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(id: 'div2', type: PrintElementType.line, x: 1, y: 9, w: 180),
    PrintElement(
      id: 'lines_table', type: PrintElementType.table, bind: 'lines',
      x: 1, y: 10, w: 180,
      columns: [
        PrintTableColumn(bind: 'inv_bill_no', label: 'Invoice/Bill No', width: 50),
        PrintTableColumn(bind: 'inv_bill_date', label: 'Date', width: 30),
        PrintTableColumn(bind: 'bill_currency', label: 'Currency', width: 25),
        PrintTableColumn(bind: 'applied_amount_local', label: 'Amount Applied (Local)', width: 45, align: PrintAlign.right, format: PrintDataFormat.currency),
      ],
    ),
    PrintElement(
      id: 'local_amount', type: PrintElementType.field, bind: 'header.local_amount', label: 'Cash Received (Local): ',
      x: 1, y: 11, w: 90, font: PrintFont(size: 10, bold: true), format: PrintDataFormat.currency,
    ),
    PrintElement(
      id: 'base_amount', type: PrintElementType.field, bind: 'header.base_amount', label: 'Cash Received (Base): ',
      x: 2, y: 11, w: 85, font: PrintFont(size: 10), format: PrintDataFormat.currency,
    ),
    PrintElement(
      id: 'total_local', type: PrintElementType.field, bind: 'header.total_local_equivalent', label: 'Total (Local Equivalent): ',
      x: 1, y: 12, w: 90, font: PrintFont(size: 10, bold: true), format: PrintDataFormat.currency,
    ),
    PrintElement(
      id: 'remarks', type: PrintElementType.field, bind: 'header.remarks', label: 'Remarks: ',
      x: 1, y: 13, w: 180, font: PrintFont(size: 9),
    ),
    PrintElement(id: 'div3', type: PrintElementType.line, x: 1, y: 14, w: 180),
    PrintElement(
      id: 'prepared_by', type: PrintElementType.field, bind: 'signatures.prepared_by', label: 'Collected By: ',
      x: 1, y: 15, w: 90, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
    PrintElement(
      id: 'authorised_by', type: PrintElementType.field, bind: 'signatures.authorised_by', label: 'Authorised Signatory: ',
      x: 2, y: 15, w: 90, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
  ],
);
