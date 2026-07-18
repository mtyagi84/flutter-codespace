import '../print_models.dart';

/// Hardcoded fallback used whenever a company has no active
/// ric_print_templates row for document_type='STOCK_TRANSFER'. Field
/// bindings match the document map built by StockTransferEntryScreen's
/// Print handler — see that screen's `_buildPrintDocument()`. Same
/// two-table (lines + charges) shape as grn_default_template.dart, but with
/// only a single Charges total (no tax/discount — transfers are internal
/// movements, never a taxable third-party purchase).
const stockTransferDefaultTemplate = PrintTemplate(
  documentType: 'STOCK_TRANSFER',
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
      id: 'title', type: PrintElementType.text, text: 'STOCK TRANSFER',
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
      id: 'transfer_no', type: PrintElementType.field, bind: 'header.transfer_no', label: 'Transfer No: ',
      x: 1, y: 7, w: 90, font: PrintFont(size: 10, bold: true),
    ),
    PrintElement(
      id: 'transfer_date', type: PrintElementType.field, bind: 'header.transfer_date', label: 'Date: ',
      x: 2, y: 7, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'from_location', type: PrintElementType.field, bind: 'header.from_location_name', label: 'From: ',
      x: 1, y: 8, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'to_location', type: PrintElementType.field, bind: 'header.to_location_name', label: 'To: ',
      x: 2, y: 8, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'mode', type: PrintElementType.field, bind: 'header.mode_label', label: 'Mode: ',
      x: 1, y: 9, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(id: 'div2', type: PrintElementType.line, x: 1, y: 10, w: 180),
    PrintElement(
      id: 'lines_table', type: PrintElementType.table, bind: 'lines',
      x: 1, y: 11, w: 180,
      columns: [
        PrintTableColumn(bind: 'product_name', label: 'Item', width: 70),
        PrintTableColumn(bind: 'base_qty', label: 'Qty', width: 20, align: PrintAlign.right, format: PrintDataFormat.number),
        PrintTableColumn(bind: 'unit_value', label: 'Unit Value', width: 30, align: PrintAlign.right, format: PrintDataFormat.currency),
        PrintTableColumn(bind: 'charge_amount', label: 'Charges', width: 30, align: PrintAlign.right, format: PrintDataFormat.currency),
      ],
    ),
    PrintElement(
      id: 'charges_table', type: PrintElementType.table, bind: 'charges',
      x: 1, y: 12, w: 180,
      columns: [
        PrintTableColumn(bind: 'charge_name', label: 'Charge', width: 120),
        PrintTableColumn(bind: 'amount', label: 'Amount', width: 60, align: PrintAlign.right, format: PrintDataFormat.currency),
      ],
    ),
    PrintElement(
      id: 'remarks', type: PrintElementType.field, bind: 'header.remarks', label: 'Remarks: ',
      x: 1, y: 13, w: 180, font: PrintFont(size: 9),
    ),
    PrintElement(id: 'totals_spacer_1', type: PrintElementType.text, text: '', x: 1, y: 14, w: 110),
    PrintElement(
      id: 'charges_total', type: PrintElementType.field, bind: 'totals.charges_amount', label: 'Total Charges: ',
      x: 2, y: 14, w: 70, format: PrintDataFormat.currency,
      font: PrintFont(size: 13, bold: true, align: PrintAlign.right, colorHex: '#1B3A6B'),
    ),
    PrintElement(id: 'div3', type: PrintElementType.line, x: 1, y: 15, w: 180),
    PrintElement(
      id: 'dispatched_by', type: PrintElementType.field, bind: 'signatures.prepared_by', label: 'Dispatched By: ',
      x: 1, y: 16, w: 80, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
    PrintElement(
      id: 'authorised_by', type: PrintElementType.field, bind: 'signatures.authorised_by', label: 'Authorised Signatory: ',
      x: 2, y: 16, w: 80, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
  ],
);
