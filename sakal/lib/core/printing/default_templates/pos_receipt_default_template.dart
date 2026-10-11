import '../print_models.dart';

/// Hardcoded fallback for document_type='POS_RECEIPT' — a narrow thermal-
/// roll receipt, NOT the back-office A4 Sales Invoice layout. Built because
/// POS was found (2026-10-11) to be reusing `salesInvoiceDefaultTemplate`
/// (an A4 page with a full letterhead/signature block) for every till sale,
/// which is wrong for a receipt printer. `paperProfile: receipt80mm` routes
/// this through `PdfFlowRenderer` (print_engine.dart already selects the
/// renderer by `paperProfile.isReceipt`) — a top-to-bottom flow with no
/// columns, where `x`/`y`/`w` are ignored entirely; only list order and
/// `font.align` matter. 80mm is the more common POS roll width; a terminal
/// configured for 58mm gets the same element list re-rendered at the
/// narrower width by `_printReceipt()` constructing a fresh PrintTemplate
/// with `paperProfile: receipt58mm` — see pos_new_sale_screen.dart.
///
/// Field bindings match the document map `PosNewSaleScreen._buildPrintDocument()`
/// builds — same `header.*`/`lines`/`totals.*` shape the back-office
/// template already used, plus POS-only keys (cashier/terminal/tender).
const posReceiptDefaultTemplate = PrintTemplate(
  documentType: 'POS_RECEIPT',
  templateName: 'Default',
  paperProfile: PaperProfile.receipt80mm,
  isDefault: true,
  elements: [
    PrintElement(id: 'company_name', type: PrintElementType.field, bind: 'company.company_name',
        font: PrintFont(size: 12, bold: true, align: PrintAlign.center)),
    PrintElement(id: 'company_address', type: PrintElementType.field, bind: 'company.address',
        font: PrintFont(size: 8, align: PrintAlign.center)),
    PrintElement(id: 'company_city', type: PrintElementType.field, bind: 'company.city_name',
        font: PrintFont(size: 8, align: PrintAlign.center)),
    PrintElement(id: 'div1', type: PrintElementType.line),
    PrintElement(id: 'title', type: PrintElementType.text, text: 'SALES RECEIPT',
        font: PrintFont(size: 10, bold: true, align: PrintAlign.center)),
    PrintElement(id: 'invoice_no', type: PrintElementType.field, bind: 'header.invoice_no', label: 'Receipt No: ',
        font: PrintFont(size: 8)),
    PrintElement(id: 'invoice_date', type: PrintElementType.field, bind: 'header.invoice_date', label: 'Date: ',
        font: PrintFont(size: 8)),
    PrintElement(id: 'cashier', type: PrintElementType.field, bind: 'header.cashier_name', label: 'Cashier: ',
        font: PrintFont(size: 8)),
    PrintElement(id: 'terminal', type: PrintElementType.field, bind: 'header.terminal_name', label: 'Till: ',
        font: PrintFont(size: 8)),
    PrintElement(id: 'customer', type: PrintElementType.field, bind: 'header.customer_name', label: 'Customer: ',
        font: PrintFont(size: 8),
        showWhen: PrintCondition(field: 'header.sale_type', equals: 'CREDIT')),
    PrintElement(id: 'div2', type: PrintElementType.line),
    PrintElement(
      id: 'lines_table', type: PrintElementType.table, bind: 'lines',
      columns: [
        PrintTableColumn(bind: 'product_name', label: 'Item'),
        PrintTableColumn(bind: 'base_qty', label: 'Qty', format: PrintDataFormat.number),
        PrintTableColumn(bind: 'rate', label: 'Rate', format: PrintDataFormat.currency),
        // Blank on an ordinary line (bound value is null there — see
        // PosNewSaleScreen._buildPrintDocument), so a plain sale's receipt
        // is unchanged; a scheme-discounted line shows what was knocked
        // off so qty x rate - Promo = Amount visibly reconciles, instead
        // of the printed Amount just looking wrong with no explanation —
        // real bug reported live 2026-10-11 (security-gate reconciliation
        // concern: the receipt gave no indication a unit was free).
        PrintTableColumn(bind: 'scheme_discount_amount', label: 'Promo', format: PrintDataFormat.currency),
        PrintTableColumn(bind: 'final_amount', label: 'Amount', format: PrintDataFormat.currency),
      ],
    ),
    PrintElement(id: 'div3', type: PrintElementType.line),
    PrintElement(id: 'gross', type: PrintElementType.field, bind: 'totals.gross_amount', label: 'Subtotal: ',
        font: PrintFont(size: 8, align: PrintAlign.right), format: PrintDataFormat.currency),
    PrintElement(id: 'discount', type: PrintElementType.field, bind: 'totals.discount_amount', label: 'Discount: ',
        font: PrintFont(size: 8, align: PrintAlign.right), format: PrintDataFormat.currency),
    PrintElement(id: 'tax', type: PrintElementType.field, bind: 'totals.tax_amount', label: 'Tax: ',
        font: PrintFont(size: 8, align: PrintAlign.right), format: PrintDataFormat.currency),
    PrintElement(id: 'grand_total', type: PrintElementType.field, bind: 'totals.grand_total', label: 'TOTAL: ',
        font: PrintFont(size: 11, bold: true, align: PrintAlign.right), format: PrintDataFormat.currency),
    PrintElement(id: 'div4', type: PrintElementType.line),
    PrintElement(id: 'tendered', type: PrintElementType.field, bind: 'totals.collected_amount', label: 'Tendered: ',
        font: PrintFont(size: 8, align: PrintAlign.right), format: PrintDataFormat.currency,
        showWhen: PrintCondition(field: 'header.sale_type', equals: 'CASH')),
    PrintElement(id: 'change', type: PrintElementType.field, bind: 'totals.change_amount', label: 'Change: ',
        font: PrintFont(size: 8, align: PrintAlign.right), format: PrintDataFormat.currency,
        showWhen: PrintCondition(field: 'header.sale_type', equals: 'CASH')),
    PrintElement(id: 'loyalty_note', type: PrintElementType.text, text: 'Loyalty points updated on your account.',
        font: PrintFont(size: 8, align: PrintAlign.center),
        showWhen: PrintCondition(field: 'header.has_loyalty', equals: 'true')),
    PrintElement(id: 'div5', type: PrintElementType.line),
    PrintElement(id: 'thank_you', type: PrintElementType.text, text: 'Thank you for shopping with us!',
        font: PrintFont(size: 8, align: PrintAlign.center)),
  ],
);
