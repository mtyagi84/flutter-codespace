import '../print_models.dart';

/// Hardcoded fallback used whenever a company has no active
/// ric_print_templates row for document_type='PRICE_MASTER'. Field
/// bindings match the document map built by
/// PriceMasterEntryScreen's Print handler — see that screen's
/// `_buildPrintDocument()`. No totals block — this is a rate list, not a
/// transaction, mirrors stock_adjustment_default_template.dart's shape
/// (also never posts to GL).
const priceMasterDefaultTemplate = PrintTemplate(
  documentType: 'PRICE_MASTER',
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
      id: 'title', type: PrintElementType.text, text: 'SALES PRICE MASTER',
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
      id: 'entry_no', type: PrintElementType.field, bind: 'header.entry_no', label: 'Entry No: ',
      x: 1, y: 7, w: 90, font: PrintFont(size: 10, bold: true),
    ),
    PrintElement(
      id: 'entry_date', type: PrintElementType.field, bind: 'header.entry_date', label: 'Date: ',
      x: 2, y: 7, w: 45, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'effective_date', type: PrintElementType.field, bind: 'header.effective_date', label: 'Effective: ',
      x: 3, y: 7, w: 45, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'location', type: PrintElementType.field, bind: 'header.location_name', label: 'Location: ',
      x: 1, y: 8, w: 60, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'price_type', type: PrintElementType.field, bind: 'header.price_type_label', label: 'Price Type: ',
      x: 2, y: 8, w: 60, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'currency', type: PrintElementType.field, bind: 'header.currency_code', label: 'Currency: ',
      x: 3, y: 8, w: 60, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'customer', type: PrintElementType.field, bind: 'header.customer_name', label: 'Customer: ',
      x: 1, y: 9, w: 180, font: PrintFont(size: 10),
    ),
    PrintElement(id: 'div2', type: PrintElementType.line, x: 1, y: 10, w: 180),
    PrintElement(
      id: 'lines_table', type: PrintElementType.table, bind: 'lines',
      x: 1, y: 11, w: 180,
      columns: [
        PrintTableColumn(bind: 'product_name', label: 'Item', width: 65),
        PrintTableColumn(bind: 'uom_label', label: 'UOM', width: 25),
        PrintTableColumn(bind: 'cost_price', label: 'Cost', width: 30, align: PrintAlign.right, format: PrintDataFormat.currency),
        PrintTableColumn(bind: 'margin_percent', label: 'Margin %', width: 25, align: PrintAlign.right, format: PrintDataFormat.number),
        PrintTableColumn(bind: 'selling_price', label: 'Selling Price', width: 35, align: PrintAlign.right, format: PrintDataFormat.currency),
      ],
    ),
    PrintElement(
      id: 'remarks', type: PrintElementType.field, bind: 'header.remarks', label: 'Remarks: ',
      x: 1, y: 12, w: 180, font: PrintFont(size: 9),
    ),
    PrintElement(id: 'div3', type: PrintElementType.line, x: 1, y: 13, w: 180),
    PrintElement(
      id: 'prepared_by', type: PrintElementType.field, bind: 'signatures.prepared_by', label: 'Prepared By: ',
      x: 1, y: 14, w: 80, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
    PrintElement(
      id: 'authorised_by', type: PrintElementType.field, bind: 'signatures.authorised_by', label: 'Authorised Signatory: ',
      x: 2, y: 14, w: 80, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
  ],
);
