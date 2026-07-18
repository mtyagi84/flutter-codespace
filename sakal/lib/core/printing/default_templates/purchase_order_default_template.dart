import '../print_models.dart';

/// Hardcoded fallback used whenever a company has no active
/// ric_print_templates row for document_type='PURCHASE_ORDER' — i.e. always,
/// until the template designer screen (Phase 2) exists and someone saves a
/// custom one. Field bindings match the document map built by
/// PurchaseOrderEntryScreen's Print handler — see that screen's
/// `_buildPrintDocument()`.
///
/// x/y here are ordering/grouping keys for the flowing canvas renderer, not
/// literal coordinates — elements sharing a `y` sit side by side in one row
/// (e.g. PO No + Date); see pdf_canvas_renderer.dart's class comment. Kept
/// as clean sequential integers since the exact magnitude no longer matters,
/// only the relative order.
const purchaseOrderDefaultTemplate = PrintTemplate(
  documentType: 'PURCHASE_ORDER',
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
      id: 'title', type: PrintElementType.text, text: 'PURCHASE ORDER',
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
      id: 'po_no', type: PrintElementType.field, bind: 'header.order_no', label: 'PO No: ',
      x: 1, y: 7, w: 90, font: PrintFont(size: 10, bold: true),
    ),
    PrintElement(
      id: 'po_date', type: PrintElementType.field, bind: 'header.order_date', label: 'Date: ',
      x: 2, y: 7, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'supplier', type: PrintElementType.field, bind: 'header.supplier_name', label: 'Supplier: ',
      x: 1, y: 8, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'buyer', type: PrintElementType.field, bind: 'header.buyer_name', label: 'Buyer: ',
      x: 2, y: 8, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'currency', type: PrintElementType.field, bind: 'header.currency_code', label: 'Currency: ',
      x: 1, y: 9, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'po_type', type: PrintElementType.field, bind: 'header.po_type', label: 'Type: ',
      x: 2, y: 9, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'bill_to', type: PrintElementType.field, bind: 'header.bill_to', label: 'Bill To: ',
      x: 1, y: 10, w: 90, font: PrintFont(size: 9),
    ),
    PrintElement(
      id: 'ship_to', type: PrintElementType.field, bind: 'header.ship_to', label: 'Ship To: ',
      x: 2, y: 10, w: 85, font: PrintFont(size: 9),
    ),
    PrintElement(id: 'div2', type: PrintElementType.line, x: 1, y: 11, w: 180),
    PrintElement(
      id: 'lines_table', type: PrintElementType.table, bind: 'lines',
      x: 1, y: 12, w: 180,
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
      x: 1, y: 13, w: 180,
      columns: [
        PrintTableColumn(bind: 'charge_name', label: 'Charge', width: 120),
        PrintTableColumn(bind: 'amount', label: 'Amount', width: 60, align: PrintAlign.right, format: PrintDataFormat.currency),
      ],
    ),
    PrintElement(
      id: 'terms_table', type: PrintElementType.table, bind: 'paymentTerms',
      x: 1, y: 14, w: 180,
      columns: [
        PrintTableColumn(bind: 'term_name', label: 'Payment Term', width: 60),
        PrintTableColumn(bind: 'description', label: 'Description', width: 120),
      ],
    ),
    PrintElement(
      id: 'remarks', type: PrintElementType.field, bind: 'header.remarks', label: 'Remarks: ',
      x: 1, y: 15, w: 180, font: PrintFont(size: 9),
    ),
    // Totals — right-aligned via a wide empty spacer + a narrower value
    // field, since the flowing row model has no dedicated "align right"
    // container of its own.
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
      id: 'tax', type: PrintElementType.field, bind: 'totals.item_tax_amount', label: 'Tax: ',
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
      id: 'prepared_by', type: PrintElementType.field, bind: 'signatures.prepared_by', label: 'Prepared By: ',
      x: 1, y: 22, w: 80, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
    PrintElement(
      id: 'authorised_by', type: PrintElementType.field, bind: 'signatures.authorised_by', label: 'Authorised Signatory: ',
      x: 2, y: 22, w: 80, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
  ],
);
