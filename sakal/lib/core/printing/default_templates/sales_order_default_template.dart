import '../print_models.dart';

/// Hardcoded fallback used whenever a company has no active
/// ric_print_templates row for document_type='SALES_ORDER'. Field
/// bindings match the document map built by SalesOrderEntryScreen's
/// Print handler — see that screen's `_buildPrintDocument()`.
///
/// x/y here are ordering/grouping keys for the flowing canvas renderer, not
/// literal coordinates — elements sharing a `y` sit side by side in one row;
/// see pdf_canvas_renderer.dart's class comment.
const salesOrderDefaultTemplate = PrintTemplate(
  documentType: 'SALES_ORDER',
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
      id: 'title', type: PrintElementType.text, text: 'SALES ORDER',
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
      id: 'order_no', type: PrintElementType.field, bind: 'header.order_no', label: 'Order No: ',
      x: 1, y: 7, w: 90, font: PrintFont(size: 10, bold: true),
    ),
    PrintElement(
      id: 'order_date', type: PrintElementType.field, bind: 'header.order_date', label: 'Date: ',
      x: 2, y: 7, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'customer', type: PrintElementType.field, bind: 'header.customer_name', label: 'Customer: ',
      x: 1, y: 8, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'customer_po_ref', type: PrintElementType.field, bind: 'header.customer_po_ref', label: 'Customer PO Ref: ',
      x: 2, y: 8, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'sales_person', type: PrintElementType.field, bind: 'header.sales_person_name', label: 'Sales Person: ',
      x: 1, y: 9, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'currency', type: PrintElementType.field, bind: 'header.currency_code', label: 'Currency: ',
      x: 2, y: 9, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'source_quotation', type: PrintElementType.field, bind: 'header.source_quotation', label: 'Against Quotation: ',
      x: 1, y: 10, w: 90, font: PrintFont(size: 9),
      showWhen: PrintCondition(field: 'header.order_mode', equals: 'Against Quotation'),
    ),
    PrintElement(
      id: 'ship_to', type: PrintElementType.field, bind: 'header.ship_to', label: 'Ship To: ',
      x: 1, y: 10.5, w: 90, font: PrintFont(size: 9),
    ),
    PrintElement(
      id: 'bill_to', type: PrintElementType.field, bind: 'header.bill_to', label: 'Bill To: ',
      x: 2, y: 10.5, w: 85, font: PrintFont(size: 9),
    ),
    PrintElement(
      id: 'payment_terms', type: PrintElementType.field, bind: 'header.payment_term_name', label: 'Payment Terms: ',
      x: 1, y: 11, w: 90, font: PrintFont(size: 9),
    ),
    PrintElement(
      id: 'incoterm', type: PrintElementType.field, bind: 'header.incoterm_label', label: 'Incoterm: ',
      x: 2, y: 11, w: 85, font: PrintFont(size: 9),
    ),
    PrintElement(
      id: 'expected_delivery_date', type: PrintElementType.field, bind: 'header.expected_delivery_date', label: 'Expected Delivery: ',
      x: 1, y: 11.3, w: 90, font: PrintFont(size: 9),
    ),
    PrintElement(
      id: 'delivery_instructions', type: PrintElementType.field, bind: 'header.delivery_instructions', label: 'Delivery Instructions: ',
      x: 2, y: 11.3, w: 85, font: PrintFont(size: 9),
    ),
    PrintElement(id: 'div2', type: PrintElementType.line, x: 1, y: 12, w: 180),
    PrintElement(
      id: 'lines_table', type: PrintElementType.table, bind: 'lines',
      x: 1, y: 13, w: 180,
      columns: [
        PrintTableColumn(bind: 'product_name', label: 'Item', width: 80),
        PrintTableColumn(bind: 'uom_label', label: 'UOM', width: 20, align: PrintAlign.center),
        PrintTableColumn(bind: 'base_qty', label: 'Qty', width: 20, align: PrintAlign.right, format: PrintDataFormat.number),
        PrintTableColumn(bind: 'rate', label: 'Rate', width: 30, align: PrintAlign.right, format: PrintDataFormat.currency),
        PrintTableColumn(bind: 'final_amount', label: 'Amount', width: 30, align: PrintAlign.right, format: PrintDataFormat.currency),
      ],
    ),
    PrintElement(
      id: 'charges_table', type: PrintElementType.table, bind: 'charges',
      x: 1, y: 14, w: 180,
      columns: [
        PrintTableColumn(bind: 'charge_name', label: 'Charge', width: 120),
        PrintTableColumn(bind: 'amount', label: 'Amount', width: 60, align: PrintAlign.right, format: PrintDataFormat.currency),
      ],
    ),
    PrintElement(
      id: 'remarks', type: PrintElementType.field, bind: 'header.remarks', label: 'Remarks: ',
      x: 1, y: 15, w: 180, font: PrintFont(size: 9),
    ),
    // Totals — right-aligned via a wide empty spacer + a narrower value field.
    PrintElement(id: 'totals_spacer_1', type: PrintElementType.text, text: '', x: 1, y: 16, w: 110),
    PrintElement(
      id: 'gross', type: PrintElementType.field, bind: 'totals.gross_amount', label: 'Gross Amount: ',
      x: 2, y: 16, w: 70, format: PrintDataFormat.currency, font: PrintFont(size: 10, align: PrintAlign.right),
    ),
    PrintElement(id: 'totals_spacer_2', type: PrintElementType.text, text: '', x: 1, y: 17, w: 110),
    PrintElement(
      id: 'discount', type: PrintElementType.field, bind: 'totals.discount_amount', label: 'Discount: ',
      x: 2, y: 17, w: 70, format: PrintDataFormat.currency, font: PrintFont(size: 10, align: PrintAlign.right),
    ),
    PrintElement(id: 'totals_spacer_3', type: PrintElementType.text, text: '', x: 1, y: 18, w: 110),
    PrintElement(
      id: 'tax', type: PrintElementType.field, bind: 'totals.tax_amount', label: 'Tax: ',
      x: 2, y: 18, w: 70, format: PrintDataFormat.currency, font: PrintFont(size: 10, align: PrintAlign.right),
    ),
    PrintElement(id: 'totals_spacer_4', type: PrintElementType.text, text: '', x: 1, y: 19, w: 110),
    PrintElement(
      id: 'charges_total', type: PrintElementType.field, bind: 'totals.charges_amount', label: 'Charges: ',
      x: 2, y: 19, w: 70, format: PrintDataFormat.currency, font: PrintFont(size: 10, align: PrintAlign.right),
    ),
    PrintElement(id: 'totals_spacer_5', type: PrintElementType.text, text: '', x: 1, y: 20, w: 110),
    PrintElement(
      id: 'grand_total', type: PrintElementType.field, bind: 'totals.grand_total', label: 'Grand Total: ',
      x: 2, y: 20, w: 70, format: PrintDataFormat.currency,
      font: PrintFont(size: 13, bold: true, align: PrintAlign.right, colorHex: '#1B3A6B'),
    ),
    PrintElement(id: 'div3', type: PrintElementType.line, x: 1, y: 21, w: 180),
    PrintElement(
      id: 'prepared_by', type: PrintElementType.text, text: 'Prepared By',
      x: 1, y: 22, w: 80, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
    PrintElement(
      id: 'authorised_by', type: PrintElementType.text, text: 'Authorised Signatory',
      x: 2, y: 22, w: 80, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
  ],
);
