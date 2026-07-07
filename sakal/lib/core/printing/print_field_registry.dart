import 'print_models.dart';

/// What a Field/Image/Barcode/Watermark-condition element can bind to, per
/// document type — drives the designer's dropdowns instead of making an
/// admin type raw path strings. A new document type (Quotation, Invoice,
/// POS Receipt, ...) registers its available fields here when its print
/// support is built; nothing elsewhere needs to change.
class PrintFieldDef {
  final String path;   // dotted path into the document map, e.g. 'header.order_no'
  final String label;  // shown in the designer's dropdown
  final PrintDataFormat suggestedFormat;

  const PrintFieldDef(this.path, this.label, [this.suggestedFormat = PrintDataFormat.text]);
}

class PrintFieldRegistry {
  PrintFieldRegistry._();

  static const _poScalarFields = [
    PrintFieldDef('header.order_no', 'PO Number'),
    PrintFieldDef('header.order_date', 'PO Date'),
    PrintFieldDef('header.status', 'Status'),
    PrintFieldDef('header.supplier_name', 'Supplier Name'),
    PrintFieldDef('header.buyer_name', 'Buyer Name'),
    PrintFieldDef('header.currency_code', 'Currency'),
    PrintFieldDef('header.po_type', 'PO Type'),
    PrintFieldDef('header.bill_to', 'Bill To'),
    PrintFieldDef('header.ship_to', 'Ship To'),
    PrintFieldDef('header.remarks', 'Remarks'),
    PrintFieldDef('totals.gross_amount', 'Gross Amount', PrintDataFormat.currency),
    PrintFieldDef('totals.discount_amount', 'Discount', PrintDataFormat.currency),
    PrintFieldDef('totals.item_tax_amount', 'Item Tax', PrintDataFormat.currency),
    PrintFieldDef('totals.charges_amount', 'Charges', PrintDataFormat.currency),
    PrintFieldDef('totals.grand_total', 'Grand Total', PrintDataFormat.currency),
  ];

  static const _grnScalarFields = [
    PrintFieldDef('header.grn_no', 'GRN Number'),
    PrintFieldDef('header.grn_date', 'GRN Date'),
    PrintFieldDef('header.status', 'Status'),
    PrintFieldDef('header.receipt_mode', 'Receipt Mode'),
    PrintFieldDef('header.supplier_name', 'Supplier Name'),
    PrintFieldDef('header.currency_code', 'Currency'),
    PrintFieldDef('header.supplier_delivery_no', 'Supplier Delivery No'),
    PrintFieldDef('header.bill_to', 'Bill To'),
    PrintFieldDef('header.ship_to', 'Ship To'),
    PrintFieldDef('header.remarks', 'Remarks'),
    PrintFieldDef('totals.gross_amount', 'Gross Amount', PrintDataFormat.currency),
    PrintFieldDef('totals.discount_amount', 'Discount', PrintDataFormat.currency),
    PrintFieldDef('totals.item_tax_amount', 'Item Tax', PrintDataFormat.currency),
    PrintFieldDef('totals.charges_amount', 'Charges', PrintDataFormat.currency),
    PrintFieldDef('totals.grand_total', 'Grand Total', PrintDataFormat.currency),
  ];

  static const _purchaseInvoiceScalarFields = [
    PrintFieldDef('header.invoice_no', 'Bill Number'),
    PrintFieldDef('header.invoice_date', 'Bill Date'),
    PrintFieldDef('header.status', 'Status'),
    PrintFieldDef('header.supplier_name', 'Supplier Name'),
    PrintFieldDef('header.currency_code', 'Currency'),
    PrintFieldDef('header.supplier_invoice_no', 'Supplier Invoice No'),
    PrintFieldDef('header.supplier_invoice_date', 'Supplier Invoice Date'),
    PrintFieldDef('header.remarks', 'Remarks'),
    PrintFieldDef('totals.taxable_amount', 'Taxable Amount', PrintDataFormat.currency),
    PrintFieldDef('totals.tax_amount', 'VAT / Tax Amount', PrintDataFormat.currency),
    PrintFieldDef('totals.invoice_total', 'Invoice Total', PrintDataFormat.currency),
  ];

  static const _purchaseReturnScalarFields = [
    PrintFieldDef('header.return_no', 'Return Number'),
    PrintFieldDef('header.return_date', 'Return Date'),
    PrintFieldDef('header.status', 'Status'),
    PrintFieldDef('header.supplier_name', 'Supplier Name'),
    PrintFieldDef('header.currency_code', 'Currency'),
    PrintFieldDef('header.reason', 'Reason'),
    PrintFieldDef('header.remarks', 'Remarks'),
    PrintFieldDef('totals.taxable_amount', 'Taxable Amount', PrintDataFormat.currency),
    PrintFieldDef('totals.tax_amount', 'VAT / Tax Amount', PrintDataFormat.currency),
    PrintFieldDef('totals.return_total', 'Return Total', PrintDataFormat.currency),
  ];

  static const _voucherScalarFields = [
    PrintFieldDef('header.voucher_type_label', 'Voucher Type'),
    PrintFieldDef('header.voucher_no', 'Voucher No'),
    PrintFieldDef('header.trans_date', 'Date'),
    PrintFieldDef('header.cash_bank_account', 'Cash/Bank Account'),
    PrintFieldDef('header.payment_mode', 'Payment Mode'),
    PrintFieldDef('header.ref_no', 'Ref No'),
    PrintFieldDef('header.currency_line', 'Currency Line (pre-formatted)'),
    PrintFieldDef('header.remarks', 'Remarks'),
    PrintFieldDef('header.party_name', 'Party Name (Against Bill)'),
    PrintFieldDef('totals.total_display', 'Total (pre-formatted)'),
    PrintFieldDef('signatures.prepared_by', 'Prepared By'),
    PrintFieldDef('signatures.authorised_by', 'Authorised By'),
  ];

  static const _materialRequisitionScalarFields = [
    PrintFieldDef('header.requisition_no', 'Requisition Number'),
    PrintFieldDef('header.requisition_date', 'Requisition Date'),
    PrintFieldDef('header.status', 'Status'),
    PrintFieldDef('header.location_name', 'Location'),
    PrintFieldDef('header.requested_by', 'Requested By'),
    PrintFieldDef('header.reason', 'Reason'),
    PrintFieldDef('header.remarks', 'Remarks'),
  ];

  static const _materialIssueScalarFields = [
    PrintFieldDef('header.issue_no', 'Issue Number'),
    PrintFieldDef('header.issue_date', 'Issue Date'),
    PrintFieldDef('header.status', 'Status'),
    PrintFieldDef('header.location_name', 'Location'),
    PrintFieldDef('header.remarks', 'Remarks'),
  ];

  static const _stockTransferRequestScalarFields = [
    PrintFieldDef('header.request_no', 'Request Number'),
    PrintFieldDef('header.request_date', 'Request Date'),
    PrintFieldDef('header.status', 'Status'),
    PrintFieldDef('header.from_location_name', 'From Location'),
    PrintFieldDef('header.to_location_name', 'To Location'),
    PrintFieldDef('header.remarks', 'Remarks'),
  ];

  static const _stockTransferScalarFields = [
    PrintFieldDef('header.transfer_no', 'Transfer Number'),
    PrintFieldDef('header.transfer_date', 'Transfer Date'),
    PrintFieldDef('header.status', 'Status'),
    PrintFieldDef('header.from_location_name', 'From Location'),
    PrintFieldDef('header.to_location_name', 'To Location'),
    PrintFieldDef('header.mode_label', 'Mode'),
    PrintFieldDef('header.remarks', 'Remarks'),
    PrintFieldDef('totals.charges_amount', 'Charges', PrintDataFormat.currency),
  ];

  static const _stockReceiptScalarFields = [
    PrintFieldDef('header.receipt_no', 'Receipt Number'),
    PrintFieldDef('header.receipt_date', 'Receipt Date'),
    PrintFieldDef('header.status', 'Status'),
    PrintFieldDef('header.source_transfer_no', 'Source Transfer No'),
    PrintFieldDef('header.from_location_name', 'From Location'),
    PrintFieldDef('header.to_location_name', 'To Location'),
    PrintFieldDef('header.remarks', 'Remarks'),
  ];

  static const _stockAdjustmentScalarFields = [
    PrintFieldDef('header.adjustment_no', 'Adjustment Number'),
    PrintFieldDef('header.adjustment_date', 'Adjustment Date'),
    PrintFieldDef('header.status', 'Status'),
    PrintFieldDef('header.location_name', 'Location'),
    PrintFieldDef('header.reason', 'Reason'),
    PrintFieldDef('header.remarks', 'Remarks'),
  ];

  static const _companyFields = [
    PrintFieldDef('company.company_name', 'Company Name'),
    PrintFieldDef('company.address', 'Company Address'),
    PrintFieldDef('company.city_name', 'Company City'),
    PrintFieldDef('company.logo', 'Company Logo (image)'),
  ];

  static const _poTableRowFields = {
    'lines': [
      PrintFieldDef('product_name', 'Item Name'),
      PrintFieldDef('uom_label', 'UOM'),
      PrintFieldDef('base_qty', 'Quantity', PrintDataFormat.number),
      PrintFieldDef('rate', 'Rate', PrintDataFormat.currency),
      PrintFieldDef('final_amount', 'Amount', PrintDataFormat.currency),
    ],
    'charges': [
      PrintFieldDef('charge_name', 'Charge Name'),
      PrintFieldDef('amount', 'Amount', PrintDataFormat.currency),
    ],
    'paymentTerms': [
      PrintFieldDef('term_name', 'Term'),
      PrintFieldDef('description', 'Description'),
    ],
  };

  static const _grnTableRowFields = {
    'lines': [
      PrintFieldDef('product_name', 'Item Name'),
      PrintFieldDef('uom_label', 'UOM'),
      PrintFieldDef('base_qty', 'Quantity', PrintDataFormat.number),
      PrintFieldDef('rate', 'Rate', PrintDataFormat.currency),
      PrintFieldDef('final_amount', 'Amount', PrintDataFormat.currency),
    ],
    'charges': [
      PrintFieldDef('charge_name', 'Charge Name'),
      PrintFieldDef('amount', 'Amount', PrintDataFormat.currency),
    ],
  };

  static const _voucherTableRowFields = {
    'lines': [
      PrintFieldDef('particulars', 'Particulars'),
      PrintFieldDef('amount', 'Amount', PrintDataFormat.currency),
      PrintFieldDef('party_amount', 'Party Amount (pre-formatted)'),
      PrintFieldDef('remarks', 'Remarks'),
    ],
  };

  static const _purchaseInvoiceTableRowFields = {
    'grns': [
      PrintFieldDef('grn_no', 'GRN Number'),
      PrintFieldDef('grn_date', 'GRN Date'),
      PrintFieldDef('currency_code', 'Currency'),
    ],
  };

  static const _purchaseReturnTableRowFields = {
    'lines': [
      PrintFieldDef('product_name', 'Item Name'),
      PrintFieldDef('source_grn_no', 'Source GRN No'),
      PrintFieldDef('return_qty', 'Return Quantity', PrintDataFormat.number),
      PrintFieldDef('rate', 'Rate', PrintDataFormat.currency),
      PrintFieldDef('final_amount', 'Amount', PrintDataFormat.currency),
    ],
  };

  static const _materialRequisitionTableRowFields = {
    'lines': [
      PrintFieldDef('product_name', 'Item Name'),
      PrintFieldDef('uom_label', 'UOM'),
      PrintFieldDef('base_qty', 'Quantity', PrintDataFormat.number),
      PrintFieldDef('department_name', 'Department'),
      PrintFieldDef('area_name', 'Consumption Area'),
      PrintFieldDef('remarks', 'Remarks'),
    ],
  };

  static const _materialIssueTableRowFields = {
    'lines': [
      PrintFieldDef('product_name', 'Item Name'),
      PrintFieldDef('source_requisition_no', 'Source Requisition No'),
      PrintFieldDef('issue_qty', 'Issued Quantity', PrintDataFormat.number),
      PrintFieldDef('department_name', 'Department'),
      PrintFieldDef('area_name', 'Consumption Area'),
    ],
  };

  static const _stockTransferRequestTableRowFields = {
    'lines': [
      PrintFieldDef('product_name', 'Item Name'),
      PrintFieldDef('uom_label', 'UOM'),
      PrintFieldDef('base_qty', 'Quantity', PrintDataFormat.number),
      PrintFieldDef('remarks', 'Remarks'),
    ],
  };

  static const _stockTransferTableRowFields = {
    'lines': [
      PrintFieldDef('product_name', 'Item Name'),
      PrintFieldDef('base_qty', 'Quantity', PrintDataFormat.number),
      PrintFieldDef('unit_value', 'Unit Value', PrintDataFormat.currency),
      PrintFieldDef('charge_amount', 'Charges', PrintDataFormat.currency),
    ],
    'charges': [
      PrintFieldDef('charge_name', 'Charge Name'),
      PrintFieldDef('amount', 'Amount', PrintDataFormat.currency),
    ],
  };

  static const _stockReceiptTableRowFields = {
    'lines': [
      PrintFieldDef('product_name', 'Item Name'),
      PrintFieldDef('dispatched_qty', 'Dispatched Quantity', PrintDataFormat.number),
      PrintFieldDef('received_qty', 'Received Quantity', PrintDataFormat.number),
      PrintFieldDef('shortfall_qty', 'Shortfall', PrintDataFormat.number),
    ],
  };

  static const _stockAdjustmentTableRowFields = {
    'lines': [
      PrintFieldDef('product_name', 'Item Name'),
      PrintFieldDef('direction', 'Direction'),
      PrintFieldDef('base_qty', 'Quantity', PrintDataFormat.number),
      PrintFieldDef('system_qty', 'System Quantity', PrintDataFormat.number),
    ],
  };

  /// Every scalar field (usable by text/field/image/barcode/watermark
  /// elements) available for a document type, company fields included.
  static List<PrintFieldDef> scalarFields(String documentType) => [
    ...switch (documentType) {
      'PURCHASE_ORDER'          => _poScalarFields,
      'GRN'                     => _grnScalarFields,
      'PURCHASE_INVOICE'        => _purchaseInvoiceScalarFields,
      'PURCHASE_RETURN'         => _purchaseReturnScalarFields,
      'VOUCHER'                 => _voucherScalarFields,
      'MATERIAL_REQUISITION'    => _materialRequisitionScalarFields,
      'MATERIAL_ISSUE'          => _materialIssueScalarFields,
      'STOCK_TRANSFER_REQUEST'  => _stockTransferRequestScalarFields,
      'STOCK_TRANSFER'          => _stockTransferScalarFields,
      'STOCK_RECEIPT'           => _stockReceiptScalarFields,
      'STOCK_ADJUSTMENT'        => _stockAdjustmentScalarFields,
      _ => const <PrintFieldDef>[],
    },
    ..._companyFields,
  ];

  /// Which repeating lists (table `bind` values) exist for a document type.
  static List<String> tableNames(String documentType) => switch (documentType) {
    'PURCHASE_ORDER'          => const ['lines', 'charges', 'paymentTerms'],
    'GRN'                     => const ['lines', 'charges'],
    'PURCHASE_INVOICE'        => const ['grns'],
    'PURCHASE_RETURN'         => const ['lines'],
    'VOUCHER'                 => const ['lines'],
    'MATERIAL_REQUISITION'    => const ['lines'],
    'MATERIAL_ISSUE'          => const ['lines'],
    'STOCK_TRANSFER_REQUEST'  => const ['lines'],
    'STOCK_TRANSFER'          => const ['lines', 'charges'],
    'STOCK_RECEIPT'           => const ['lines'],
    'STOCK_ADJUSTMENT'        => const ['lines'],
    _ => const [],
  };

  /// Columns available for a table bound to [tableName] within [documentType].
  static List<PrintFieldDef> rowFields(String documentType, String tableName) => switch (documentType) {
    'PURCHASE_ORDER'          => _poTableRowFields[tableName] ?? const [],
    'GRN'                     => _grnTableRowFields[tableName] ?? const [],
    'PURCHASE_INVOICE'        => _purchaseInvoiceTableRowFields[tableName] ?? const [],
    'PURCHASE_RETURN'         => _purchaseReturnTableRowFields[tableName] ?? const [],
    'VOUCHER'                 => _voucherTableRowFields[tableName] ?? const [],
    'MATERIAL_REQUISITION'    => _materialRequisitionTableRowFields[tableName] ?? const [],
    'MATERIAL_ISSUE'          => _materialIssueTableRowFields[tableName] ?? const [],
    'STOCK_TRANSFER_REQUEST'  => _stockTransferRequestTableRowFields[tableName] ?? const [],
    'STOCK_TRANSFER'          => _stockTransferTableRowFields[tableName] ?? const [],
    'STOCK_RECEIPT'           => _stockReceiptTableRowFields[tableName] ?? const [],
    'STOCK_ADJUSTMENT'        => _stockAdjustmentTableRowFields[tableName] ?? const [],
    _ => const [],
  };

  /// Document types the designer currently knows how to edit. Matches
  /// print_template_provider.dart's fallback registry — add a new type to
  /// both places (plus a *_default_template.dart and field entries here)
  /// when a new document's print support is built.
  static const documentTypes = [
    'PURCHASE_ORDER', 'GRN', 'PURCHASE_INVOICE', 'PURCHASE_RETURN', 'VOUCHER',
    'MATERIAL_REQUISITION', 'MATERIAL_ISSUE', 'STOCK_TRANSFER_REQUEST', 'STOCK_TRANSFER', 'STOCK_RECEIPT',
    'STOCK_ADJUSTMENT',
  ];

  static String documentTypeLabel(String documentType) => switch (documentType) {
    'PURCHASE_ORDER'          => 'Purchase Order',
    'GRN'                     => 'Goods Receipt Note',
    'PURCHASE_INVOICE'        => 'Purchase Bill',
    'PURCHASE_RETURN'         => 'Purchase Return',
    'VOUCHER'                 => 'Finance Voucher',
    'MATERIAL_REQUISITION'    => 'Material Requisition',
    'MATERIAL_ISSUE'          => 'Material Issue',
    'STOCK_TRANSFER_REQUEST'  => 'Stock Transfer Request',
    'STOCK_TRANSFER'          => 'Stock Transfer',
    'STOCK_RECEIPT'           => 'Stock Receipt',
    'STOCK_ADJUSTMENT'        => 'Stock Adjustment',
    _ => documentType,
  };
}
