import '../print_models.dart';

/// Hardcoded fallback used whenever a company has no active
/// ric_print_templates row for document_type='PURCHASE_INVOICE'. Field
/// bindings match the document map built by PurchaseInvoiceEntryScreen's
/// Print handler — see that screen's `_buildPrintDocument()`. Same
/// row-grouping/flex-weight model as grn_default_template.dart.
const purchaseInvoiceDefaultTemplate = PrintTemplate(
  documentType: 'PURCHASE_INVOICE',
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
      id: 'title', type: PrintElementType.text, text: 'PURCHASE BILL',
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
      id: 'invoice_no', type: PrintElementType.field, bind: 'header.invoice_no', label: 'Bill No: ',
      x: 1, y: 7, w: 90, font: PrintFont(size: 10, bold: true),
    ),
    PrintElement(
      id: 'invoice_date', type: PrintElementType.field, bind: 'header.invoice_date', label: 'Bill Date: ',
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
      id: 'supplier_invoice_no', type: PrintElementType.field, bind: 'header.supplier_invoice_no', label: 'Supplier Invoice No: ',
      x: 1, y: 9, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'supplier_invoice_date', type: PrintElementType.field, bind: 'header.supplier_invoice_date', label: 'Supplier Invoice Date: ',
      x: 2, y: 9, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(id: 'div2', type: PrintElementType.line, x: 1, y: 10, w: 180),
    PrintElement(
      id: 'grns_table', type: PrintElementType.table, bind: 'grns',
      x: 1, y: 11, w: 180,
      columns: [
        PrintTableColumn(bind: 'grn_no', label: 'GRN No', width: 90),
        PrintTableColumn(bind: 'grn_date', label: 'GRN Date', width: 50),
        PrintTableColumn(bind: 'currency_code', label: 'Currency', width: 40, align: PrintAlign.center),
      ],
    ),
    PrintElement(
      id: 'remarks', type: PrintElementType.field, bind: 'header.remarks', label: 'Remarks: ',
      x: 1, y: 12, w: 180, font: PrintFont(size: 9),
    ),
    PrintElement(id: 'totals_spacer_1', type: PrintElementType.text, text: '', x: 1, y: 13, w: 110),
    PrintElement(
      id: 'taxable_amount', type: PrintElementType.field, bind: 'totals.taxable_amount', label: 'Taxable Amount: ',
      x: 2, y: 13, w: 70, format: PrintDataFormat.currency, font: PrintFont(size: 10, align: PrintAlign.right),
    ),
    PrintElement(id: 'totals_spacer_2', type: PrintElementType.text, text: '', x: 1, y: 14, w: 110),
    PrintElement(
      id: 'tax_amount', type: PrintElementType.field, bind: 'totals.tax_amount', label: 'VAT / Tax: ',
      x: 2, y: 14, w: 70, format: PrintDataFormat.currency, font: PrintFont(size: 10, align: PrintAlign.right),
    ),
    PrintElement(id: 'totals_spacer_3', type: PrintElementType.text, text: '', x: 1, y: 15, w: 110),
    PrintElement(
      id: 'invoice_total', type: PrintElementType.field, bind: 'totals.invoice_total', label: 'Invoice Total: ',
      x: 2, y: 15, w: 70, format: PrintDataFormat.currency,
      font: PrintFont(size: 13, bold: true, align: PrintAlign.right, colorHex: '#1B3A6B'),
    ),
    PrintElement(id: 'div3', type: PrintElementType.line, x: 1, y: 16, w: 180),
    PrintElement(
      id: 'prepared_by', type: PrintElementType.field, bind: 'signatures.prepared_by', label: 'Prepared By: ',
      x: 1, y: 17, w: 80, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
    PrintElement(
      id: 'authorised_by', type: PrintElementType.field, bind: 'signatures.authorised_by', label: 'Authorised Signatory: ',
      x: 2, y: 17, w: 80, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
  ],
);
