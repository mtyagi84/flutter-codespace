import '../print_models.dart';

/// Hardcoded fallback used whenever a company has no active
/// ric_print_templates row for document_type='OPENING_STOCK'. Field
/// bindings match the document map built by
/// OpeningStockEntryScreen's Print handler — see that screen's
/// `_buildPrintDocument()`. No totals block — mirrors stock_adjustment_
/// default_template.dart's shape (this document also never posts to GL).
const openingStockDefaultTemplate = PrintTemplate(
  documentType: 'OPENING_STOCK',
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
      id: 'title', type: PrintElementType.text, text: 'OPENING STOCK',
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
      id: 'opening_no', type: PrintElementType.field, bind: 'header.opening_no', label: 'Opening No: ',
      x: 1, y: 7, w: 90, font: PrintFont(size: 10, bold: true),
    ),
    PrintElement(
      id: 'opening_date', type: PrintElementType.field, bind: 'header.opening_date', label: 'Date: ',
      x: 2, y: 7, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'location', type: PrintElementType.field, bind: 'header.location_name', label: 'Location: ',
      x: 1, y: 8, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(id: 'div2', type: PrintElementType.line, x: 1, y: 9, w: 180),
    PrintElement(
      id: 'lines_table', type: PrintElementType.table, bind: 'lines',
      x: 1, y: 10, w: 180,
      columns: [
        PrintTableColumn(bind: 'product_name', label: 'Item', width: 55),
        PrintTableColumn(bind: 'batch_no', label: 'Batch', width: 25),
        PrintTableColumn(bind: 'serial_no', label: 'Serial', width: 25),
        PrintTableColumn(bind: 'base_qty', label: 'Qty', width: 20, align: PrintAlign.right, format: PrintDataFormat.number),
        PrintTableColumn(bind: 'unit_cost', label: 'Unit Cost', width: 25, align: PrintAlign.right, format: PrintDataFormat.currency),
        PrintTableColumn(bind: 'amount', label: 'Amount', width: 30, align: PrintAlign.right, format: PrintDataFormat.currency),
      ],
    ),
    PrintElement(
      id: 'remarks', type: PrintElementType.field, bind: 'header.remarks', label: 'Remarks: ',
      x: 1, y: 11, w: 180, font: PrintFont(size: 9),
    ),
    PrintElement(id: 'div3', type: PrintElementType.line, x: 1, y: 12, w: 180),
    PrintElement(
      id: 'prepared_by', type: PrintElementType.text, text: 'Prepared By',
      x: 1, y: 13, w: 80, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
    PrintElement(
      id: 'authorised_by', type: PrintElementType.text, text: 'Authorised Signatory',
      x: 2, y: 13, w: 80, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
  ],
);
