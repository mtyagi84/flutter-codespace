import '../print_models.dart';

/// Hardcoded fallback used whenever a company has no active
/// ric_print_templates row for document_type='SALES_INVOICE'. Field
/// bindings match the document map built by SalesInvoiceEntryScreen's
/// Print handler — see that screen's `_buildPrintDocument()`.
///
/// This is the single most important print target in the app — the
/// customer-facing receipt. Works purely from in-memory screen state (no
/// network calls), so an offline, not-yet-synced invoice (invoice_no
/// still a LOCAL-... placeholder) prints identically, just with the
/// PROVISIONAL watermark instead of DRAFT.
const salesInvoiceDefaultTemplate = PrintTemplate(
  documentType: 'SALES_INVOICE',
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
      id: 'title', type: PrintElementType.text, text: 'SALES INVOICE',
      x: 1, y: 5, w: 180,
      font: PrintFont(size: 18, bold: true, align: PrintAlign.center, colorHex: '#1B3A6B'),
    ),
    PrintElement(
      id: 'provisional_watermark', type: PrintElementType.watermark,
      text: 'PROVISIONAL — PENDING SYNC',
      x: 1, y: 6, w: 180,
      showWhen: PrintCondition(field: 'header.provisional', equals: 'true'),
    ),
    PrintElement(
      id: 'draft_watermark', type: PrintElementType.watermark,
      text: 'DRAFT — PENDING MANAGER REVIEW',
      x: 1, y: 6, w: 180,
      showWhen: PrintCondition(field: 'header.status', equals: 'DRAFT'),
    ),
    PrintElement(
      id: 'invoice_no', type: PrintElementType.field, bind: 'header.invoice_no', label: 'Invoice No: ',
      x: 1, y: 7, w: 90, font: PrintFont(size: 10, bold: true),
    ),
    PrintElement(
      id: 'invoice_date', type: PrintElementType.field, bind: 'header.invoice_date', label: 'Date: ',
      x: 2, y: 7, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'sale_type', type: PrintElementType.field, bind: 'header.sale_type', label: 'Sale Type: ',
      x: 1, y: 8, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'currency', type: PrintElementType.field, bind: 'header.currency_code', label: 'Currency: ',
      x: 2, y: 8, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'customer', type: PrintElementType.field, bind: 'header.customer_name', label: 'Customer: ',
      x: 1, y: 9, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'sales_person', type: PrintElementType.field, bind: 'header.sales_person_name', label: 'Sales Person: ',
      x: 2, y: 9, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'party_phone', type: PrintElementType.field, bind: 'header.party_phone', label: 'Mobile: ',
      x: 1, y: 10, w: 90, font: PrintFont(size: 9),
    ),
    PrintElement(
      id: 'party_address', type: PrintElementType.field, bind: 'header.party_address', label: 'Address: ',
      x: 2, y: 10, w: 85, font: PrintFont(size: 9),
    ),
    PrintElement(id: 'div2', type: PrintElementType.line, x: 1, y: 11, w: 180),
    PrintElement(
      id: 'lines_table', type: PrintElementType.table, bind: 'lines',
      x: 1, y: 12, w: 180,
      columns: [
        PrintTableColumn(bind: 'product_name', label: 'Item', width: 90),
        PrintTableColumn(bind: 'uom_label', label: 'UOM', width: 20, align: PrintAlign.center),
        PrintTableColumn(bind: 'base_qty', label: 'Qty', width: 20, align: PrintAlign.right, format: PrintDataFormat.number),
        PrintTableColumn(bind: 'rate', label: 'Rate', width: 25, align: PrintAlign.right, format: PrintDataFormat.currency),
        PrintTableColumn(bind: 'final_amount', label: 'Amount', width: 25, align: PrintAlign.right, format: PrintDataFormat.currency),
      ],
    ),
    PrintElement(
      id: 'remarks', type: PrintElementType.field, bind: 'header.remarks', label: 'Remarks: ',
      x: 1, y: 13, w: 180, font: PrintFont(size: 9),
    ),
    // Totals — right-aligned via a wide empty spacer + a narrower value field.
    PrintElement(id: 'totals_spacer_1', type: PrintElementType.text, text: '', x: 1, y: 14, w: 110),
    PrintElement(
      id: 'gross', type: PrintElementType.field, bind: 'totals.gross_amount', label: 'Gross Amount: ',
      x: 2, y: 14, w: 70, format: PrintDataFormat.currency, font: PrintFont(size: 10, align: PrintAlign.right),
    ),
    PrintElement(id: 'totals_spacer_2', type: PrintElementType.text, text: '', x: 1, y: 15, w: 110),
    PrintElement(
      id: 'discount', type: PrintElementType.field, bind: 'totals.discount_amount', label: 'Discount: ',
      x: 2, y: 15, w: 70, format: PrintDataFormat.currency, font: PrintFont(size: 10, align: PrintAlign.right),
    ),
    PrintElement(id: 'totals_spacer_3', type: PrintElementType.text, text: '', x: 1, y: 16, w: 110),
    PrintElement(
      id: 'charges', type: PrintElementType.field, bind: 'totals.charges_amount', label: 'Charges: ',
      x: 2, y: 16, w: 70, format: PrintDataFormat.currency, font: PrintFont(size: 10, align: PrintAlign.right),
    ),
    PrintElement(id: 'totals_spacer_4', type: PrintElementType.text, text: '', x: 1, y: 17, w: 110),
    PrintElement(
      id: 'tax', type: PrintElementType.field, bind: 'totals.tax_amount', label: 'Tax: ',
      x: 2, y: 17, w: 70, format: PrintDataFormat.currency, font: PrintFont(size: 10, align: PrintAlign.right),
    ),
    PrintElement(id: 'totals_spacer_5', type: PrintElementType.text, text: '', x: 1, y: 18, w: 110),
    PrintElement(
      id: 'grand_total', type: PrintElementType.field, bind: 'totals.grand_total', label: 'Grand Total: ',
      x: 2, y: 18, w: 70, format: PrintDataFormat.currency,
      font: PrintFont(size: 13, bold: true, align: PrintAlign.right, colorHex: '#1B3A6B'),
    ),
    PrintElement(id: 'div3', type: PrintElementType.line, x: 1, y: 19, w: 180),
    PrintElement(
      id: 'thank_you', type: PrintElementType.text, text: 'Thank you for your business',
      x: 1, y: 20, w: 180, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
  ],
);
