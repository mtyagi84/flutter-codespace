import '../print_models.dart';

/// Hardcoded fallback used whenever a company has no active
/// ric_print_templates row for document_type='SALES_DELIVERY'. Field
/// bindings match the document map built by SalesDeliveryEntryScreen's
/// Print handler — see that screen's `_buildPrintDocument()`. Deliberately
/// non-financial — no rate/tax/amount binding exists anywhere in this
/// template, mirroring the source document's own structural absence of
/// those columns.
const salesDeliveryDefaultTemplate = PrintTemplate(
  documentType: 'SALES_DELIVERY',
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
    // Title/Delivery No/Date as a right-aligned block beside the logo/
    // company block (row 1) — same treatment as Journal Voucher, replacing
    // the old big centered banner below the divider.
    PrintElement(
      id: 'title_block', type: PrintElementType.block,
      x: 3, y: 1, w: 90, font: PrintFont(align: PrintAlign.right),
      lines: [
        PrintElement(id: 'title', type: PrintElementType.text, text: 'Delivery Note',
            font: PrintFont(size: 16, bold: true, align: PrintAlign.right, colorHex: '#1B3A6B')),
        PrintElement(id: 'delivery_no', type: PrintElementType.field, bind: 'header.delivery_no', label: 'Delivery No: ',
            font: PrintFont(size: 10, bold: true, align: PrintAlign.right)),
        PrintElement(id: 'delivery_date', type: PrintElementType.field, bind: 'header.delivery_date', label: 'Date: ',
            font: PrintFont(size: 10, align: PrintAlign.right)),
      ],
    ),
    // Accent rule under the letterhead — thicker + navy, not the default
    // thin grey divider, so the letterhead reads as a distinct block.
    PrintElement(
      id: 'div1', type: PrintElementType.line, x: 1, y: 4, w: 180,
      h: 1.4, font: PrintFont(colorHex: '#1B3A6B'),
    ),
    PrintElement(
      id: 'draft_watermark', type: PrintElementType.watermark,
      text: 'DRAFT — NOT APPROVED',
      x: 1, y: 6, w: 180,
      showWhen: PrintCondition(field: 'header.status', notEquals: 'APPROVED'),
    ),
    PrintElement(
      id: 'invoice_no', type: PrintElementType.field, bind: 'header.invoice_no', label: 'Against Invoice: ',
      x: 1, y: 8, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'customer', type: PrintElementType.field, bind: 'header.customer_name', label: 'Customer: ',
      x: 2, y: 8, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'location', type: PrintElementType.field, bind: 'header.location_name', label: 'Dispatch Location: ',
      x: 1, y: 9, w: 90, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'received_by', type: PrintElementType.field, bind: 'header.received_by_name', label: 'Received By: ',
      x: 2, y: 9, w: 85, font: PrintFont(size: 10),
    ),
    PrintElement(
      id: 'ship_to_heading', type: PrintElementType.text, text: 'SHIP TO',
      x: 1, y: 10, w: 180, font: PrintFont(size: 10, bold: true, colorHex: '#1B3A6B'),
    ),
    PrintElement(
      id: 'ship_to_location', type: PrintElementType.field, bind: 'header.ship_to_location_name',
      x: 1, y: 11, w: 180, font: PrintFont(size: 9, bold: true),
    ),
    PrintElement(
      id: 'ship_to_address1', type: PrintElementType.field, bind: 'header.ship_to_address_line1',
      x: 1, y: 12, w: 180, font: PrintFont(size: 9),
    ),
    PrintElement(
      id: 'ship_to_address2', type: PrintElementType.field, bind: 'header.ship_to_address_line2',
      x: 1, y: 13, w: 180, font: PrintFont(size: 9),
    ),
    PrintElement(
      id: 'ship_to_contact', type: PrintElementType.field, bind: 'header.ship_to_contact_person', label: 'Contact: ',
      x: 1, y: 14, w: 90, font: PrintFont(size: 9),
    ),
    PrintElement(
      id: 'ship_to_phone', type: PrintElementType.field, bind: 'header.ship_to_contact_phone', label: 'Phone: ',
      x: 2, y: 14, w: 85, font: PrintFont(size: 9),
    ),
    PrintElement(id: 'div2', type: PrintElementType.line, x: 1, y: 15, w: 180),
    PrintElement(
      id: 'lines_table', type: PrintElementType.table, bind: 'lines',
      x: 1, y: 16, w: 180,
      columns: [
        PrintTableColumn(bind: 'product_name', label: 'Item', width: 70),
        PrintTableColumn(bind: 'barcode', label: 'Barcode', width: 30),
        PrintTableColumn(bind: 'uom_name', label: 'Unit', width: 25),
        PrintTableColumn(bind: 'qty_pack', label: 'Qty Pack', width: 25, align: PrintAlign.right, format: PrintDataFormat.number),
        PrintTableColumn(bind: 'qty_loose', label: 'Qty Loose', width: 30, align: PrintAlign.right, format: PrintDataFormat.number),
      ],
    ),
    PrintElement(
      id: 'transport_heading', type: PrintElementType.text, text: 'TRANSPORT DETAILS',
      x: 1, y: 17, w: 180, font: PrintFont(size: 10, bold: true, colorHex: '#1B3A6B'),
    ),
    PrintElement(
      id: 'vehicle_no', type: PrintElementType.field, bind: 'header.vehicle_no', label: 'Vehicle No: ',
      x: 1, y: 18, w: 90, font: PrintFont(size: 9),
    ),
    PrintElement(
      id: 'transporter', type: PrintElementType.field, bind: 'header.transporter_name', label: 'Transporter: ',
      x: 2, y: 18, w: 85, font: PrintFont(size: 9),
    ),
    PrintElement(
      id: 'driver_name', type: PrintElementType.field, bind: 'header.driver_name', label: 'Driver: ',
      x: 1, y: 19, w: 90, font: PrintFont(size: 9),
    ),
    PrintElement(
      id: 'driver_phone', type: PrintElementType.field, bind: 'header.driver_phone', label: 'Driver Phone: ',
      x: 2, y: 19, w: 85, font: PrintFont(size: 9),
    ),
    PrintElement(
      id: 'remarks', type: PrintElementType.field, bind: 'header.remarks', label: 'Remarks: ',
      x: 1, y: 20, w: 180, font: PrintFont(size: 9),
    ),
    PrintElement(
      id: 'div3', type: PrintElementType.line, x: 1, y: 21, w: 180,
      h: 1.4, font: PrintFont(colorHex: '#1B3A6B'),
    ),
    // Short "sign above the line" rules, one per signature column, sitting
    // directly above the labels below.
    PrintElement(id: 'sig_line_1', type: PrintElementType.line, x: 1, y: 21.6, w: 60, h: 0.5),
    PrintElement(id: 'sig_line_2', type: PrintElementType.line, x: 2, y: 21.6, w: 60, h: 0.5),
    PrintElement(id: 'sig_line_3', type: PrintElementType.line, x: 3, y: 21.6, w: 60, h: 0.5),
    PrintElement(
      id: 'prepared_by', type: PrintElementType.field, bind: 'signatures.prepared_by', label: 'Prepared By: ',
      x: 1, y: 22, w: 60, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
    PrintElement(
      id: 'authorised_by', type: PrintElementType.field, bind: 'signatures.authorised_by', label: 'Authorised Signatory: ',
      x: 2, y: 22, w: 60, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
    PrintElement(
      id: 'received_signature', type: PrintElementType.field, bind: 'header.received_by_name', label: 'Received By (Signature): ',
      x: 3, y: 22, w: 60, font: PrintFont(size: 9, align: PrintAlign.center),
    ),
  ],
);
