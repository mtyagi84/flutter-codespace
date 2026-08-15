import '../print_models.dart';

/// Hardcoded fallback used whenever a company has no active
/// ric_print_templates row for document_type='GRN'. Field bindings match the
/// document map built by GrnEntryScreen's Print handler — see that screen's
/// `_buildPrintDocument()`. Same row-grouping/flex-weight model as
/// purchase_order_default_template.dart — see pdf_canvas_renderer.dart.
const grnDefaultTemplate = PrintTemplate(
  documentType: 'GRN',
  templateName: 'Default',
  paperProfile: PaperProfile.a4,
  isDefault: true,
  elements: [
    PrintElement(
      id: 'logo', type: PrintElementType.image, bind: 'company.logo',
      x: 1, y: 1, w: 35,
    ),
    PrintElement(
      id: 'company_block', type: PrintElementType.block,
      x: 2, y: 1, w: 140,
      lines: [
        PrintElement(id: 'company_name', type: PrintElementType.field, bind: 'company.company_name',
            font: PrintFont(size: 16, bold: true, colorHex: '#1B3A6B')),
        PrintElement(id: 'company_address', type: PrintElementType.field, bind: 'company.address',
            font: PrintFont(size: 9, colorHex: '#4A5568')),
        PrintElement(id: 'company_city', type: PrintElementType.field, bind: 'company.city_name',
            font: PrintFont(size: 9, colorHex: '#4A5568')),
      ],
    ),
    // Title/GRN No/Date as a right-aligned block beside the logo/company
    // block (row 1) — same treatment as Journal Voucher, replacing the old
    // big centered banner below the divider.
    PrintElement(
      id: 'title_block', type: PrintElementType.block,
      x: 3, y: 1, w: 90, font: PrintFont(align: PrintAlign.right),
      lines: [
        PrintElement(id: 'title', type: PrintElementType.text, text: 'Goods Receipt Note',
            font: PrintFont(size: 16, bold: true, align: PrintAlign.right, colorHex: '#1B3A6B')),
        PrintElement(id: 'grn_no', type: PrintElementType.field, bind: 'header.grn_no', label: 'GRN No: ',
            font: PrintFont(size: 10, bold: true, align: PrintAlign.right)),
        PrintElement(id: 'grn_date', type: PrintElementType.field, bind: 'header.grn_date', label: 'Date: ',
            font: PrintFont(size: 10, align: PrintAlign.right)),
      ],
    ),
    // Accent rule under the letterhead — thicker + navy, not the default
    // thin grey divider, so the letterhead reads as a distinct block.
    PrintElement(
      id: 'div1', type: PrintElementType.line, x: 1, y: 2, w: 180,
      h: 1.4, font: PrintFont(colorHex: '#1B3A6B'),
    ),
    PrintElement(
      id: 'draft_watermark', type: PrintElementType.watermark,
      text: 'DRAFT — NOT APPROVED',
      x: 1, y: 3, w: 180,
      showWhen: PrintCondition(field: 'header.status', notEquals: 'APPROVED'),
    ),
    PrintElement(
      id: 'supplier', type: PrintElementType.field, bind: 'header.supplier_name', label: 'Supplier: ',
      x: 1, y: 8, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'receipt_mode', type: PrintElementType.field, bind: 'header.receipt_mode', label: 'Mode: ',
      x: 2, y: 8, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'currency', type: PrintElementType.field, bind: 'header.currency_code', label: 'Currency: ',
      x: 1, y: 9, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'supplier_delivery_no', type: PrintElementType.field, bind: 'header.supplier_delivery_no', label: 'Delivery No: ',
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
      id: 'remarks', type: PrintElementType.field, bind: 'header.remarks', label: 'Remarks: ',
      x: 1, y: 14, w: 180, font: PrintFont(size: 9),
    ),
    // A rule directly above the totals block separates it from whatever's
    // above (table/remarks) — otherwise "Gross Amount" reads as just one
    // more (unbordered) table-less row with no visual anchor.
    PrintElement(id: 'div_totals', type: PrintElementType.line, x: 1, y: 14.5, w: 180, h: 0.5),
    PrintElement(id: 'totals_spacer_1', type: PrintElementType.text, text: '', x: 1, y: 15, w: 110),
    PrintElement(
      id: 'gross', type: PrintElementType.field, bind: 'totals.gross_amount', label: 'Gross Amount: ',
      x: 2, y: 15, w: 70, format: PrintDataFormat.currency, font: PrintFont(size: 10, align: PrintAlign.right),
    ),
    PrintElement(id: 'totals_spacer_2', type: PrintElementType.text, text: '', x: 1, y: 16, w: 110),
    PrintElement(
      id: 'discount', type: PrintElementType.field, bind: 'totals.discount_amount', label: 'Discount: ',
      x: 2, y: 16, w: 70, format: PrintDataFormat.currency, font: PrintFont(size: 10, align: PrintAlign.right),
    ),
    PrintElement(id: 'totals_spacer_3', type: PrintElementType.text, text: '', x: 1, y: 17, w: 110),
    PrintElement(
      id: 'tax', type: PrintElementType.field, bind: 'totals.item_tax_amount', label: 'Tax: ',
      x: 2, y: 17, w: 70, format: PrintDataFormat.currency, font: PrintFont(size: 10, align: PrintAlign.right),
    ),
    PrintElement(id: 'totals_spacer_4', type: PrintElementType.text, text: '', x: 1, y: 18, w: 110),
    PrintElement(
      id: 'charges_total', type: PrintElementType.field, bind: 'totals.charges_amount', label: 'Charges: ',
      x: 2, y: 18, w: 70, format: PrintDataFormat.currency, font: PrintFont(size: 10, align: PrintAlign.right),
    ),
    PrintElement(id: 'totals_spacer_5', type: PrintElementType.text, text: '', x: 1, y: 19, w: 110),
    PrintElement(
      id: 'grand_total', type: PrintElementType.field, bind: 'totals.grand_total', label: 'Grand Total: ',
      x: 2, y: 19, w: 70, format: PrintDataFormat.currency,
      font: PrintFont(size: 13, bold: true, align: PrintAlign.right, colorHex: '#1B3A6B'),
    ),
    PrintElement(
      id: 'div3', type: PrintElementType.line, x: 1, y: 20, w: 180,
      h: 1.4, font: PrintFont(colorHex: '#1B3A6B'),
    ),
    // Short "sign above the line" rules, one per signature column, sitting
    // directly above the labels below.
    PrintElement(id: 'sig_line_1', type: PrintElementType.line, x: 1, y: 20.6, w: 80, h: 0.5),
    PrintElement(id: 'sig_line_2', type: PrintElementType.line, x: 2, y: 20.6, w: 80, h: 0.5),
    PrintElement(
      id: 'received_by', type: PrintElementType.field, bind: 'signatures.prepared_by', label: 'Received By: ',
      x: 1, y: 21, w: 80, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
    PrintElement(
      id: 'authorised_by', type: PrintElementType.field, bind: 'signatures.authorised_by', label: 'Authorised Signatory: ',
      x: 2, y: 21, w: 80, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
  ],
);
