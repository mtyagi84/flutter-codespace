import '../print_models.dart';

/// Hardcoded fallback for document_type='POS_RETURN_RECEIPT' — the receipt-
/// roll counterpart to `salesReturnDefaultTemplate` (A4), same reasoning as
/// `pos_receipt_default_template.dart`. Field bindings match the document
/// map `PosReturnScreen._buildPrintDocument()` builds.
const posReturnReceiptDefaultTemplate = PrintTemplate(
  documentType: 'POS_RETURN_RECEIPT',
  templateName: 'Default',
  paperProfile: PaperProfile.receipt80mm,
  isDefault: true,
  elements: [
    PrintElement(id: 'company_name', type: PrintElementType.field, bind: 'company.company_name',
        font: PrintFont(size: 12, bold: true, align: PrintAlign.center)),
    PrintElement(id: 'company_address', type: PrintElementType.field, bind: 'company.address',
        font: PrintFont(size: 8, align: PrintAlign.center)),
    PrintElement(id: 'div1', type: PrintElementType.line),
    PrintElement(id: 'title', type: PrintElementType.text, text: 'RETURN RECEIPT',
        font: PrintFont(size: 10, bold: true, align: PrintAlign.center)),
    PrintElement(id: 'return_no', type: PrintElementType.field, bind: 'header.return_no', label: 'Return No: ',
        font: PrintFont(size: 8)),
    PrintElement(id: 'return_date', type: PrintElementType.field, bind: 'header.return_date', label: 'Date: ',
        font: PrintFont(size: 8)),
    PrintElement(id: 'invoice_no', type: PrintElementType.field, bind: 'header.invoice_no', label: 'Against Receipt: ',
        font: PrintFont(size: 8)),
    PrintElement(id: 'cashier', type: PrintElementType.field, bind: 'header.cashier_name', label: 'Cashier: ',
        font: PrintFont(size: 8)),
    PrintElement(id: 'reason', type: PrintElementType.field, bind: 'header.reason', label: 'Reason: ',
        font: PrintFont(size: 8)),
    PrintElement(id: 'div2', type: PrintElementType.line),
    PrintElement(
      id: 'lines_table', type: PrintElementType.table, bind: 'lines',
      columns: [
        PrintTableColumn(bind: 'product_name', label: 'Item'),
        PrintTableColumn(bind: 'return_qty', label: 'Qty', format: PrintDataFormat.number),
        PrintTableColumn(bind: 'rate', label: 'Rate', format: PrintDataFormat.currency),
        PrintTableColumn(bind: 'final_amount', label: 'Amount', format: PrintDataFormat.currency),
      ],
    ),
    PrintElement(id: 'div3', type: PrintElementType.line),
    PrintElement(id: 'taxable_amount', type: PrintElementType.field, bind: 'totals.taxable_amount', label: 'Taxable Amount: ',
        font: PrintFont(size: 8, align: PrintAlign.right), format: PrintDataFormat.currency),
    PrintElement(id: 'tax_amount', type: PrintElementType.field, bind: 'totals.tax_amount', label: 'Tax: ',
        font: PrintFont(size: 8, align: PrintAlign.right), format: PrintDataFormat.currency),
    PrintElement(id: 'return_total', type: PrintElementType.field, bind: 'totals.return_total', label: 'REFUND TOTAL: ',
        font: PrintFont(size: 11, bold: true, align: PrintAlign.right), format: PrintDataFormat.currency),
    PrintElement(id: 'div4', type: PrintElementType.line),
    PrintElement(id: 'thank_you', type: PrintElementType.text, text: 'Thank you',
        font: PrintFont(size: 8, align: PrintAlign.center)),
  ],
);
