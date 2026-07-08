import '../print_models.dart';

/// Hardcoded fallback used whenever a company has no active
/// ric_print_templates row for document_type='STOCK_COUNT_REVIEW'. Field
/// bindings match the document map built by
/// StockCountReviewEntryScreen's Print handler — see that screen's
/// `_buildPrintDocument()`. Only postable (non-zero, non-exception)
/// variance rows are included — the report a manager actually needs is
/// "what got adjusted," not the full clubbed grid.
const stockCountReviewDefaultTemplate = PrintTemplate(
  documentType: 'STOCK_COUNT_REVIEW',
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
      id: 'title', type: PrintElementType.text, text: 'STOCK COUNT REVIEW — VARIANCE REPORT',
      x: 1, y: 5, w: 180,
      font: PrintFont(size: 16, bold: true, align: PrintAlign.center, colorHex: '#1B3A6B'),
    ),
    PrintElement(
      id: 'draft_watermark', type: PrintElementType.watermark,
      text: 'DRAFT — NOT APPROVED',
      x: 1, y: 6, w: 180,
      showWhen: PrintCondition(field: 'header.status', notEquals: 'APPROVED'),
    ),
    PrintElement(
      id: 'review_no', type: PrintElementType.field, bind: 'header.review_no', label: 'Review No: ',
      x: 1, y: 7, w: 90, font: PrintFont(size: 10, bold: true),
    ),
    PrintElement(
      id: 'review_date', type: PrintElementType.field, bind: 'header.review_date', label: 'Review Date: ',
      x: 2, y: 7, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'location', type: PrintElementType.field, bind: 'header.location_name', label: 'Location: ',
      x: 1, y: 8, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'as_of_date', type: PrintElementType.field, bind: 'header.as_of_date', label: 'As Of: ',
      x: 2, y: 8, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'posted_adjustment', type: PrintElementType.field, bind: 'header.posted_adjustment_no', label: 'Stock Adjustment: ',
      x: 1, y: 9, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(id: 'div2', type: PrintElementType.line, x: 1, y: 10, w: 180),
    PrintElement(
      id: 'lines_table', type: PrintElementType.table, bind: 'lines',
      x: 1, y: 11, w: 180,
      columns: [
        PrintTableColumn(bind: 'product_name', label: 'Item', width: 60),
        PrintTableColumn(bind: 'batch_no', label: 'Batch', width: 20),
        PrintTableColumn(bind: 'serial_no', label: 'Serial', width: 20),
        PrintTableColumn(bind: 'counted_qty', label: 'Counted', width: 20, align: PrintAlign.right, format: PrintDataFormat.number),
        PrintTableColumn(bind: 'system_qty', label: 'System', width: 20, align: PrintAlign.right, format: PrintDataFormat.number),
        PrintTableColumn(bind: 'variance_qty', label: 'Variance', width: 20, align: PrintAlign.right, format: PrintDataFormat.number),
        PrintTableColumn(bind: 'adjust_flag', label: '+/-', width: 20, align: PrintAlign.center),
      ],
    ),
    PrintElement(
      id: 'remarks', type: PrintElementType.field, bind: 'header.remarks', label: 'Remarks: ',
      x: 1, y: 12, w: 180, font: PrintFont(size: 9),
    ),
    PrintElement(id: 'div3', type: PrintElementType.line, x: 1, y: 13, w: 180),
    PrintElement(
      id: 'prepared_by', type: PrintElementType.text, text: 'Reviewed By',
      x: 1, y: 14, w: 80, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
    PrintElement(
      id: 'authorised_by', type: PrintElementType.text, text: 'Authorised Signatory',
      x: 2, y: 14, w: 80, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
  ],
);
