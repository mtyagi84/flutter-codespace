import '../print_models.dart';

/// Hardcoded fallback used whenever a company has no active
/// ric_print_templates row for document_type='STOCK_RECEIPT'. Field bindings
/// match the document map built by StockReceiptEntryScreen's Print handler —
/// see that screen's `_buildPrintDocument()`. No totals block — a receipt's
/// landed value is derived server-side at Approve, never known to the entry
/// screen's own state.
const stockReceiptDefaultTemplate = PrintTemplate(
  documentType: 'STOCK_RECEIPT',
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
      id: 'title', type: PrintElementType.text, text: 'STOCK RECEIPT',
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
      id: 'source_transfer', type: PrintElementType.field, bind: 'header.source_transfer_no', label: 'Source Transfer: ',
      x: 1, y: 8, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'from_location', type: PrintElementType.field, bind: 'header.from_location_name', label: 'From: ',
      x: 2, y: 8, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'to_location', type: PrintElementType.field, bind: 'header.to_location_name', label: 'To: ',
      x: 1, y: 9, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(id: 'div2', type: PrintElementType.line, x: 1, y: 10, w: 180),
    PrintElement(
      id: 'lines_table', type: PrintElementType.table, bind: 'lines',
      x: 1, y: 11, w: 180,
      columns: [
        PrintTableColumn(bind: 'product_name', label: 'Item', width: 70),
        PrintTableColumn(bind: 'dispatched_qty', label: 'Dispatched', width: 35, align: PrintAlign.right, format: PrintDataFormat.number),
        PrintTableColumn(bind: 'received_qty', label: 'Received', width: 35, align: PrintAlign.right, format: PrintDataFormat.number),
        PrintTableColumn(bind: 'shortfall_qty', label: 'Shortfall', width: 40, align: PrintAlign.right, format: PrintDataFormat.number),
      ],
    ),
    PrintElement(
      id: 'remarks', type: PrintElementType.field, bind: 'header.remarks', label: 'Remarks: ',
      x: 1, y: 12, w: 180, font: PrintFont(size: 9),
    ),
    PrintElement(id: 'div3', type: PrintElementType.line, x: 1, y: 13, w: 180),
    PrintElement(
      id: 'received_by', type: PrintElementType.field, bind: 'signatures.prepared_by', label: 'Received By: ',
      x: 1, y: 14, w: 80, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
    PrintElement(
      id: 'authorised_by', type: PrintElementType.field, bind: 'signatures.authorised_by', label: 'Authorised Signatory: ',
      x: 2, y: 14, w: 80, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
  ],
);
