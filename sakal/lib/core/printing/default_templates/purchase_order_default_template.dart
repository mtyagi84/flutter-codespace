import '../print_models.dart';

/// Hardcoded fallback used whenever a company has no active
/// ric_print_templates row for document_type='PURCHASE_ORDER' — i.e. always,
/// until the template designer screen (Phase 2) exists and someone saves a
/// custom one. Field bindings match the document map built by
/// PurchaseOrderEntryScreen's Print handler — see that screen's
/// `_buildPrintDocument()`.
const purchaseOrderDefaultTemplate = PrintTemplate(
  documentType: 'PURCHASE_ORDER',
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
      id: 'title', type: PrintElementType.text, text: 'PURCHASE ORDER',
      x: 15, y: 42, w: 180, h: 10,
      font: const PrintFont(size: 16, bold: true, align: PrintAlign.center),
    ),
    PrintElement(
      id: 'draft_watermark', type: PrintElementType.watermark,
      text: 'DRAFT — NOT APPROVED',
      showWhen: const PrintCondition(field: 'header.status', notEquals: 'APPROVED'),
    ),
    PrintElement(
      id: 'po_no', type: PrintElementType.field, bind: 'header.order_no', label: 'PO No: ',
      x: 15, y: 56, w: 90, h: 6, font: const PrintFont(size: 10, bold: true),
    ),
    PrintElement(
      id: 'po_date', type: PrintElementType.field, bind: 'header.order_date', label: 'Date: ',
      x: 110, y: 56, w: 85, h: 6, font: const PrintFont(size: 10),
    ),
    PrintElement(
      id: 'supplier', type: PrintElementType.field, bind: 'header.supplier_name', label: 'Supplier: ',
      x: 15, y: 63, w: 90, h: 6, font: const PrintFont(size: 10),
    ),
    PrintElement(
      id: 'buyer', type: PrintElementType.field, bind: 'header.buyer_name', label: 'Buyer: ',
      x: 110, y: 63, w: 85, h: 6, font: const PrintFont(size: 10),
    ),
    PrintElement(
      id: 'currency', type: PrintElementType.field, bind: 'header.currency_code', label: 'Currency: ',
      x: 15, y: 70, w: 90, h: 6, font: const PrintFont(size: 10),
    ),
    PrintElement(
      id: 'po_type', type: PrintElementType.field, bind: 'header.po_type', label: 'Type: ',
      x: 110, y: 70, w: 85, h: 6, font: const PrintFont(size: 10),
    ),
    PrintElement(id: 'div2', type: PrintElementType.line, x: 15, y: 78, w: 180, h: 1),
    PrintElement(
      id: 'lines_table', type: PrintElementType.table, bind: 'lines',
      x: 15, y: 82, w: 180, h: 90,
      columns: const [
        PrintTableColumn(bind: 'product_name', label: 'Item', width: 80),
        PrintTableColumn(bind: 'uom_label', label: 'UOM', width: 20, align: PrintAlign.center),
        PrintTableColumn(bind: 'base_qty', label: 'Qty', width: 20, align: PrintAlign.right, format: PrintDataFormat.number),
        PrintTableColumn(bind: 'rate', label: 'Rate', width: 30, align: PrintAlign.right, format: PrintDataFormat.currency),
        PrintTableColumn(bind: 'final_amount', label: 'Amount', width: 30, align: PrintAlign.right, format: PrintDataFormat.currency),
      ],
    ),
    PrintElement(
      id: 'charges_table', type: PrintElementType.table, bind: 'charges',
      x: 15, y: 176, w: 180, h: 20,
      columns: const [
        PrintTableColumn(bind: 'charge_name', label: 'Charge', width: 120),
        PrintTableColumn(bind: 'amount', label: 'Amount', width: 60, align: PrintAlign.right, format: PrintDataFormat.currency),
      ],
    ),
    PrintElement(
      id: 'terms_table', type: PrintElementType.table, bind: 'paymentTerms',
      x: 15, y: 198, w: 180, h: 20,
      columns: const [
        PrintTableColumn(bind: 'term_name', label: 'Payment Term', width: 60),
        PrintTableColumn(bind: 'description', label: 'Description', width: 120),
      ],
    ),
    PrintElement(
      id: 'grand_total', type: PrintElementType.field, bind: 'totals.grand_total', label: 'Grand Total: ',
      x: 115, y: 222, w: 80, h: 8,
      font: const PrintFont(size: 12, bold: true, align: PrintAlign.right),
    ),
    PrintElement(id: 'div3', type: PrintElementType.line, x: 15, y: 250, w: 180, h: 1),
    PrintElement(
      id: 'prepared_by', type: PrintElementType.text, text: 'Prepared By',
      x: 15, y: 255, w: 80, h: 6, font: const PrintFont(size: 9, align: PrintAlign.center),
    ),
    PrintElement(
      id: 'authorised_by', type: PrintElementType.text, text: 'Authorised Signatory',
      x: 115, y: 255, w: 80, h: 6, font: const PrintFont(size: 9, align: PrintAlign.center),
    ),
  ],
);
