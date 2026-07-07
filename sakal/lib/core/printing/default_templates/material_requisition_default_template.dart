import '../print_models.dart';

/// Hardcoded fallback used whenever a company has no active
/// ric_print_templates row for document_type='MATERIAL_REQUISITION'. Field
/// bindings match the document map built by MaterialRequisitionEntryScreen's
/// Print handler — see that screen's `_buildPrintDocument()`. Same
/// row-grouping/flex-weight model as purchase_return_default_template.dart.
/// No totals block — a requisition is a pure quantity intent document, no
/// monetary value.
const materialRequisitionDefaultTemplate = PrintTemplate(
  documentType: 'MATERIAL_REQUISITION',
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
      id: 'title', type: PrintElementType.text, text: 'MATERIAL REQUISITION',
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
      id: 'requisition_no', type: PrintElementType.field, bind: 'header.requisition_no', label: 'Requisition No: ',
      x: 1, y: 7, w: 90, font: PrintFont(size: 10, bold: true),
    ),
    PrintElement(
      id: 'requisition_date', type: PrintElementType.field, bind: 'header.requisition_date', label: 'Date: ',
      x: 2, y: 7, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'location', type: PrintElementType.field, bind: 'header.location_name', label: 'Location: ',
      x: 1, y: 8, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'requested_by', type: PrintElementType.field, bind: 'header.requested_by', label: 'Requested By: ',
      x: 2, y: 8, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'reason', type: PrintElementType.field, bind: 'header.reason', label: 'Reason: ',
      x: 1, y: 9, w: 180, font: PrintFont(size: 9),
    ),
    PrintElement(id: 'div2', type: PrintElementType.line, x: 1, y: 10, w: 180),
    PrintElement(
      id: 'lines_table', type: PrintElementType.table, bind: 'lines',
      x: 1, y: 11, w: 180,
      columns: [
        PrintTableColumn(bind: 'product_name', label: 'Item', width: 60),
        PrintTableColumn(bind: 'uom_label', label: 'UOM', width: 20, align: PrintAlign.center),
        PrintTableColumn(bind: 'base_qty', label: 'Qty', width: 20, align: PrintAlign.right, format: PrintDataFormat.number),
        PrintTableColumn(bind: 'department_name', label: 'Department', width: 40),
        PrintTableColumn(bind: 'area_name', label: 'Consumption Area', width: 40),
      ],
    ),
    PrintElement(
      id: 'remarks', type: PrintElementType.field, bind: 'header.remarks', label: 'Remarks: ',
      x: 1, y: 12, w: 180, font: PrintFont(size: 9),
    ),
    PrintElement(id: 'div3', type: PrintElementType.line, x: 1, y: 13, w: 180),
    PrintElement(
      id: 'prepared_by', type: PrintElementType.text, text: 'Requested By',
      x: 1, y: 14, w: 80, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
    PrintElement(
      id: 'authorised_by', type: PrintElementType.text, text: 'Authorised Signatory',
      x: 2, y: 14, w: 80, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
  ],
);
