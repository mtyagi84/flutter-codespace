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

  static const _salesQuotationScalarFields = [
    PrintFieldDef('header.quotation_no', 'Quotation Number'),
    PrintFieldDef('header.quotation_date', 'Quotation Date'),
    PrintFieldDef('header.valid_until_date', 'Valid Until'),
    PrintFieldDef('header.status', 'Status'),
    PrintFieldDef('header.customer_name', 'Customer Name'),
    PrintFieldDef('header.sales_person_name', 'Sales Person'),
    PrintFieldDef('header.currency_code', 'Currency'),
    PrintFieldDef('header.payment_terms', 'Payment Terms'),
    PrintFieldDef('header.delivery_terms', 'Delivery Terms'),
    PrintFieldDef('header.remarks', 'Remarks'),
    PrintFieldDef('totals.gross_amount', 'Gross Amount', PrintDataFormat.currency),
    PrintFieldDef('totals.discount_amount', 'Discount', PrintDataFormat.currency),
    PrintFieldDef('totals.tax_amount', 'Tax', PrintDataFormat.currency),
    PrintFieldDef('totals.charges_amount', 'Charges', PrintDataFormat.currency),
    PrintFieldDef('totals.grand_total', 'Grand Total', PrintDataFormat.currency),
  ];

  static const _salesOrderScalarFields = [
    PrintFieldDef('header.order_no', 'Order Number'),
    PrintFieldDef('header.order_date', 'Order Date'),
    PrintFieldDef('header.order_mode', 'Order Mode'),
    PrintFieldDef('header.source_quotation', 'Source Quotation'),
    PrintFieldDef('header.status', 'Status'),
    PrintFieldDef('header.customer_name', 'Customer Name'),
    PrintFieldDef('header.customer_po_ref', 'Customer PO Ref'),
    PrintFieldDef('header.ship_to', 'Ship To'),
    PrintFieldDef('header.bill_to', 'Bill To'),
    PrintFieldDef('header.expected_delivery_date', 'Expected Delivery Date'),
    PrintFieldDef('header.sales_person_name', 'Sales Person'),
    PrintFieldDef('header.currency_code', 'Currency'),
    PrintFieldDef('header.payment_term_name', 'Payment Terms'),
    PrintFieldDef('header.incoterm_label', 'Incoterm'),
    PrintFieldDef('header.delivery_instructions', 'Delivery Instructions'),
    PrintFieldDef('header.remarks', 'Remarks'),
    PrintFieldDef('totals.gross_amount', 'Gross Amount', PrintDataFormat.currency),
    PrintFieldDef('totals.discount_amount', 'Discount', PrintDataFormat.currency),
    PrintFieldDef('totals.tax_amount', 'Tax', PrintDataFormat.currency),
    PrintFieldDef('totals.charges_amount', 'Charges', PrintDataFormat.currency),
    PrintFieldDef('totals.grand_total', 'Grand Total', PrintDataFormat.currency),
  ];

  static const _salesInvoiceScalarFields = [
    PrintFieldDef('header.invoice_no', 'Invoice Number'),
    PrintFieldDef('header.invoice_date', 'Invoice Date'),
    PrintFieldDef('header.provisional', 'Provisional (offline, pre-sync)'),
    PrintFieldDef('header.sale_type', 'Sale Type'),
    PrintFieldDef('header.status', 'Status'),
    PrintFieldDef('header.customer_name', 'Customer Name'),
    PrintFieldDef('header.party_phone', 'Mobile'),
    PrintFieldDef('header.party_address', 'Address'),
    PrintFieldDef('header.sales_person_name', 'Sales Person'),
    PrintFieldDef('header.currency_code', 'Currency'),
    PrintFieldDef('header.remarks', 'Remarks'),
    PrintFieldDef('totals.gross_amount', 'Gross Amount', PrintDataFormat.currency),
    PrintFieldDef('totals.discount_amount', 'Discount', PrintDataFormat.currency),
    PrintFieldDef('totals.charges_amount', 'Charges', PrintDataFormat.currency),
    PrintFieldDef('totals.tax_amount', 'Tax', PrintDataFormat.currency),
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

  static const _salesReturnScalarFields = [
    PrintFieldDef('header.return_no', 'Return Number'),
    PrintFieldDef('header.return_date', 'Return Date'),
    PrintFieldDef('header.status', 'Status'),
    PrintFieldDef('header.invoice_no', 'Against Invoice No'),
    PrintFieldDef('header.customer_name', 'Customer Name'),
    PrintFieldDef('header.currency_code', 'Currency'),
    PrintFieldDef('header.reason', 'Reason'),
    PrintFieldDef('header.remarks', 'Remarks'),
    PrintFieldDef('totals.taxable_amount', 'Taxable Amount', PrintDataFormat.currency),
    PrintFieldDef('totals.tax_amount', 'Tax Amount', PrintDataFormat.currency),
    PrintFieldDef('totals.return_total', 'Return Total', PrintDataFormat.currency),
  ];

  // Non-financial by design — no rate/tax/amount field exists anywhere on
  // this document. header.received_by_name is a free-text field the
  // dispatching staff types, distinct from signatures.authorised_by (the
  // internal approver).
  static const _salesDeliveryScalarFields = [
    PrintFieldDef('header.delivery_no', 'Delivery Number'),
    PrintFieldDef('header.delivery_date', 'Delivery Date'),
    PrintFieldDef('header.status', 'Status'),
    PrintFieldDef('header.invoice_no', 'Against Invoice No'),
    PrintFieldDef('header.invoice_date', 'Invoice Date'),
    PrintFieldDef('header.customer_name', 'Customer Name'),
    PrintFieldDef('header.location_name', 'Dispatch Location'),
    PrintFieldDef('header.ship_to_location_name', 'Ship-To Location'),
    PrintFieldDef('header.ship_to_address_line1', 'Ship-To Address Line 1'),
    PrintFieldDef('header.ship_to_address_line2', 'Ship-To Address Line 2'),
    PrintFieldDef('header.ship_to_contact_person', 'Ship-To Contact Person'),
    PrintFieldDef('header.ship_to_contact_phone', 'Ship-To Contact Phone'),
    PrintFieldDef('header.received_by_name', 'Received By'),
    PrintFieldDef('header.vehicle_no', 'Vehicle No'),
    PrintFieldDef('header.transporter_name', 'Transporter'),
    PrintFieldDef('header.driver_name', 'Driver Name'),
    PrintFieldDef('header.driver_phone', 'Driver Phone'),
    PrintFieldDef('header.reason', 'Reason'),
    PrintFieldDef('header.remarks', 'Remarks'),
  ];

  static const _cashReceiptScalarFields = [
    PrintFieldDef('header.receipt_no', 'Receipt Number'),
    PrintFieldDef('header.receipt_date', 'Receipt Date'),
    PrintFieldDef('header.status', 'Status'),
    PrintFieldDef('header.customer_name', 'Customer Name'),
    PrintFieldDef('header.location_name', 'Location'),
    PrintFieldDef('header.local_amount', 'Cash Received (Local)', PrintDataFormat.currency),
    PrintFieldDef('header.base_amount', 'Cash Received (Base)', PrintDataFormat.currency),
    PrintFieldDef('header.total_local_equivalent', 'Total (Local Equivalent)', PrintDataFormat.currency),
    PrintFieldDef('header.remarks', 'Remarks'),
  ];

  static const _expenseVoucherScalarFields = [
    PrintFieldDef('header.voucher_no', 'Voucher No'),
    PrintFieldDef('header.trans_date', 'Voucher Date'),
    PrintFieldDef('header.supplier_name', 'Supplier'),
    PrintFieldDef('header.currency_code', 'Currency'),
    PrintFieldDef('header.bill_no', 'Bill No'),
    PrintFieldDef('header.bill_date', 'Bill Date'),
    PrintFieldDef('header.remarks', 'Remarks'),
    PrintFieldDef('totals.total_expense_display', 'Total Expense (pre-formatted)'),
    PrintFieldDef('totals.net_payable_display', 'Net Payable to Supplier (pre-formatted)'),
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
    // signatures.* fields are appended to EVERY document type by
    // scalarFields() below (same idiom as _companyFields) — no longer
    // listed here specifically, to avoid a duplicate dropdown entry.
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

  static const _openingStockScalarFields = [
    PrintFieldDef('header.opening_no', 'Opening Number'),
    PrintFieldDef('header.opening_date', 'Opening Date'),
    PrintFieldDef('header.status', 'Status'),
    PrintFieldDef('header.location_name', 'Location'),
    PrintFieldDef('header.remarks', 'Remarks'),
  ];

  static const _stockCountScalarFields = [
    PrintFieldDef('header.count_no', 'Count Number'),
    PrintFieldDef('header.count_date', 'Count Date'),
    PrintFieldDef('header.status', 'Status'),
    PrintFieldDef('header.location_name', 'Location'),
    PrintFieldDef('header.category', 'Category'),
    PrintFieldDef('header.remarks', 'Remarks'),
  ];

  static const _stockCountReviewScalarFields = [
    PrintFieldDef('header.review_no', 'Review Number'),
    PrintFieldDef('header.review_date', 'Review Date'),
    PrintFieldDef('header.as_of_date', 'As Of Date'),
    PrintFieldDef('header.status', 'Status'),
    PrintFieldDef('header.location_name', 'Location'),
    PrintFieldDef('header.posted_adjustment_no', 'Posted Stock Adjustment No'),
    PrintFieldDef('header.remarks', 'Remarks'),
  ];

  static const _priceMasterScalarFields = [
    PrintFieldDef('header.entry_no', 'Entry No'),
    PrintFieldDef('header.entry_date', 'Entry Date'),
    PrintFieldDef('header.effective_date', 'Effective Date'),
    PrintFieldDef('header.status', 'Status'),
    PrintFieldDef('header.location_name', 'Location'),
    PrintFieldDef('header.price_type_label', 'Price Type'),
    PrintFieldDef('header.customer_name', 'Customer'),
    PrintFieldDef('header.currency_code', 'Currency'),
    PrintFieldDef('header.remarks', 'Remarks'),
  ];

  static const _companyFields = [
    PrintFieldDef('company.company_name', 'Company Name'),
    PrintFieldDef('company.address', 'Company Address'),
    PrintFieldDef('company.city_name', 'Company City'),
    PrintFieldDef('company.logo', 'Company Logo (image)'),
  ];

  // Every document has "Prepared By" (whoever created it — always known
  // once saved) and "Authorised By" (whoever approved it — blank until
  // approved). Appended to every document type below, same idiom as
  // _companyFields, so no per-document-type registration is needed —
  // was previously VOUCHER-only, the one gap that let every other
  // module's print show the label with no name against it.
  static const _signatureFields = [
    PrintFieldDef('signatures.prepared_by', 'Prepared By'),
    PrintFieldDef('signatures.authorised_by', 'Authorised By'),
  ];

  static const _salesOrderTableRowFields = {
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

  static const _salesInvoiceTableRowFields = {
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

  static const _salesQuotationTableRowFields = {
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

  static const _salesReturnTableRowFields = {
    'lines': [
      PrintFieldDef('product_name', 'Item Name'),
      PrintFieldDef('return_qty', 'Return Quantity', PrintDataFormat.number),
      PrintFieldDef('rate', 'Rate', PrintDataFormat.currency),
      PrintFieldDef('final_amount', 'Amount', PrintDataFormat.currency),
    ],
  };

  // No financial field exists to accidentally expose — structurally
  // non-financial, not just gated.
  static const _salesDeliveryTableRowFields = {
    'lines': [
      PrintFieldDef('product_name', 'Item Name'),
      PrintFieldDef('barcode', 'Barcode'),
      PrintFieldDef('uom_name', 'UOM'),
      PrintFieldDef('qty_pack', 'Qty Pack', PrintDataFormat.number),
      PrintFieldDef('qty_loose', 'Qty Loose', PrintDataFormat.number),
      PrintFieldDef('base_qty', 'Delivery Quantity', PrintDataFormat.number),
    ],
  };

  static const _cashReceiptTableRowFields = {
    'lines': [
      PrintFieldDef('inv_bill_no', 'Invoice/Bill No'),
      PrintFieldDef('inv_bill_date', 'Invoice/Bill Date'),
      PrintFieldDef('bill_currency', 'Currency'),
      PrintFieldDef('applied_amount_local', 'Amount Applied (Local)', PrintDataFormat.currency),
    ],
  };

  static const _expenseVoucherTableRowFields = {
    'lines': [
      PrintFieldDef('account_name', 'Expense Account'),
      PrintFieldDef('amount', 'Amount', PrintDataFormat.currency),
      PrintFieldDef('tax_group_name', 'Tax Group'),
      PrintFieldDef('remarks', 'Remarks'),
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

  static const _openingStockTableRowFields = {
    'lines': [
      PrintFieldDef('product_name', 'Item Name'),
      PrintFieldDef('batch_no', 'Batch No'),
      PrintFieldDef('serial_no', 'Serial No'),
      PrintFieldDef('base_qty', 'Quantity', PrintDataFormat.number),
      PrintFieldDef('unit_cost', 'Unit Cost', PrintDataFormat.currency),
      PrintFieldDef('amount', 'Amount', PrintDataFormat.currency),
    ],
  };

  static const _stockCountTableRowFields = {
    'lines': [
      PrintFieldDef('product_name', 'Item Name'),
      PrintFieldDef('counted_qty', 'Counted Quantity', PrintDataFormat.number),
    ],
  };

  static const _stockCountReviewTableRowFields = {
    'lines': [
      PrintFieldDef('product_name', 'Item Name'),
      PrintFieldDef('batch_no', 'Batch No'),
      PrintFieldDef('serial_no', 'Serial No'),
      PrintFieldDef('counted_qty', 'Counted Quantity', PrintDataFormat.number),
      PrintFieldDef('system_qty', 'System Quantity', PrintDataFormat.number),
      PrintFieldDef('variance_qty', 'Variance Quantity', PrintDataFormat.number),
      PrintFieldDef('adjust_flag', 'Direction'),
    ],
  };

  static const _priceMasterTableRowFields = {
    'lines': [
      PrintFieldDef('product_name', 'Item Name'),
      PrintFieldDef('uom_label', 'UOM'),
      PrintFieldDef('cost_price', 'Cost Price', PrintDataFormat.currency),
      PrintFieldDef('margin_percent', 'Margin %', PrintDataFormat.number),
      PrintFieldDef('selling_price', 'Selling Price', PrintDataFormat.currency),
    ],
  };

  /// Every scalar field (usable by text/field/image/barcode/watermark
  /// elements) available for a document type, company fields included.
  static List<PrintFieldDef> scalarFields(String documentType) => [
    ...switch (documentType) {
      'SALES_QUOTATION'         => _salesQuotationScalarFields,
      'SALES_ORDER'             => _salesOrderScalarFields,
      'PURCHASE_ORDER'          => _poScalarFields,
      'GRN'                     => _grnScalarFields,
      'PURCHASE_INVOICE'        => _purchaseInvoiceScalarFields,
      'PURCHASE_RETURN'         => _purchaseReturnScalarFields,
      'EXPENSE_VOUCHER'         => _expenseVoucherScalarFields,
      'VOUCHER'                 => _voucherScalarFields,
      'MATERIAL_REQUISITION'    => _materialRequisitionScalarFields,
      'MATERIAL_ISSUE'          => _materialIssueScalarFields,
      'STOCK_TRANSFER_REQUEST'  => _stockTransferRequestScalarFields,
      'STOCK_TRANSFER'          => _stockTransferScalarFields,
      'STOCK_RECEIPT'           => _stockReceiptScalarFields,
      'STOCK_ADJUSTMENT'        => _stockAdjustmentScalarFields,
      'OPENING_STOCK'           => _openingStockScalarFields,
      'STOCK_COUNT'             => _stockCountScalarFields,
      'STOCK_COUNT_REVIEW'      => _stockCountReviewScalarFields,
      'PRICE_MASTER'            => _priceMasterScalarFields,
      'SALES_INVOICE'           => _salesInvoiceScalarFields,
      'SALES_RETURN'            => _salesReturnScalarFields,
      'SALES_DELIVERY'          => _salesDeliveryScalarFields,
      'CASH_RECEIPT'            => _cashReceiptScalarFields,
      _ => const <PrintFieldDef>[],
    },
    ..._companyFields,
    ..._signatureFields,
  ];

  /// Which repeating lists (table `bind` values) exist for a document type.
  static List<String> tableNames(String documentType) => switch (documentType) {
    'SALES_QUOTATION'         => const ['lines', 'charges'],
    'SALES_ORDER'             => const ['lines', 'charges'],
    'PURCHASE_ORDER'          => const ['lines', 'charges', 'paymentTerms'],
    'GRN'                     => const ['lines', 'charges'],
    'PURCHASE_INVOICE'        => const ['grns'],
    'PURCHASE_RETURN'         => const ['lines'],
    'EXPENSE_VOUCHER'         => const ['lines'],
    'VOUCHER'                 => const ['lines'],
    'MATERIAL_REQUISITION'    => const ['lines'],
    'MATERIAL_ISSUE'          => const ['lines'],
    'STOCK_TRANSFER_REQUEST'  => const ['lines'],
    'STOCK_TRANSFER'          => const ['lines', 'charges'],
    'STOCK_RECEIPT'           => const ['lines'],
    'STOCK_ADJUSTMENT'        => const ['lines'],
    'OPENING_STOCK'           => const ['lines'],
    'STOCK_COUNT'             => const ['lines'],
    'STOCK_COUNT_REVIEW'      => const ['lines'],
    'PRICE_MASTER'            => const ['lines'],
    'SALES_INVOICE'           => const ['lines', 'charges'],
    'SALES_RETURN'            => const ['lines'],
    'SALES_DELIVERY'          => const ['lines'],
    'CASH_RECEIPT'            => const ['lines'],
    _ => const [],
  };

  /// Columns available for a table bound to [tableName] within [documentType].
  static List<PrintFieldDef> rowFields(String documentType, String tableName) => switch (documentType) {
    'SALES_QUOTATION'         => _salesQuotationTableRowFields[tableName] ?? const [],
    'SALES_ORDER'             => _salesOrderTableRowFields[tableName] ?? const [],
    'PURCHASE_ORDER'          => _poTableRowFields[tableName] ?? const [],
    'GRN'                     => _grnTableRowFields[tableName] ?? const [],
    'PURCHASE_INVOICE'        => _purchaseInvoiceTableRowFields[tableName] ?? const [],
    'PURCHASE_RETURN'         => _purchaseReturnTableRowFields[tableName] ?? const [],
    'EXPENSE_VOUCHER'         => _expenseVoucherTableRowFields[tableName] ?? const [],
    'VOUCHER'                 => _voucherTableRowFields[tableName] ?? const [],
    'MATERIAL_REQUISITION'    => _materialRequisitionTableRowFields[tableName] ?? const [],
    'MATERIAL_ISSUE'          => _materialIssueTableRowFields[tableName] ?? const [],
    'STOCK_TRANSFER_REQUEST'  => _stockTransferRequestTableRowFields[tableName] ?? const [],
    'STOCK_TRANSFER'          => _stockTransferTableRowFields[tableName] ?? const [],
    'STOCK_RECEIPT'           => _stockReceiptTableRowFields[tableName] ?? const [],
    'STOCK_ADJUSTMENT'        => _stockAdjustmentTableRowFields[tableName] ?? const [],
    'OPENING_STOCK'           => _openingStockTableRowFields[tableName] ?? const [],
    'STOCK_COUNT'             => _stockCountTableRowFields[tableName] ?? const [],
    'STOCK_COUNT_REVIEW'      => _stockCountReviewTableRowFields[tableName] ?? const [],
    'PRICE_MASTER'            => _priceMasterTableRowFields[tableName] ?? const [],
    'SALES_INVOICE'           => _salesInvoiceTableRowFields[tableName] ?? const [],
    'SALES_RETURN'            => _salesReturnTableRowFields[tableName] ?? const [],
    'SALES_DELIVERY'          => _salesDeliveryTableRowFields[tableName] ?? const [],
    'CASH_RECEIPT'            => _cashReceiptTableRowFields[tableName] ?? const [],
    _ => const [],
  };

  /// Document types the designer currently knows how to edit. Matches
  /// print_template_provider.dart's fallback registry — add a new type to
  /// both places (plus a *_default_template.dart and field entries here)
  /// when a new document's print support is built.
  static const documentTypes = [
    'SALES_QUOTATION', 'SALES_ORDER',
    'PURCHASE_ORDER', 'GRN', 'PURCHASE_INVOICE', 'PURCHASE_RETURN', 'VOUCHER',
    'MATERIAL_REQUISITION', 'MATERIAL_ISSUE', 'STOCK_TRANSFER_REQUEST', 'STOCK_TRANSFER', 'STOCK_RECEIPT',
    'STOCK_ADJUSTMENT', 'OPENING_STOCK', 'STOCK_COUNT', 'STOCK_COUNT_REVIEW', 'PRICE_MASTER',
    'SALES_INVOICE', 'SALES_RETURN', 'SALES_DELIVERY', 'CASH_RECEIPT', 'EXPENSE_VOUCHER',
  ];

  static String documentTypeLabel(String documentType) => switch (documentType) {
    'SALES_QUOTATION'         => 'Sales Quotation',
    'SALES_ORDER'             => 'Sales Order',
    'PURCHASE_ORDER'          => 'Purchase Order',
    'GRN'                     => 'Goods Receipt Note',
    'PURCHASE_INVOICE'        => 'Purchase Bill',
    'PURCHASE_RETURN'         => 'Purchase Return',
    'EXPENSE_VOUCHER'         => 'Expense Voucher',
    'VOUCHER'                 => 'Finance Voucher',
    'MATERIAL_REQUISITION'    => 'Material Requisition',
    'MATERIAL_ISSUE'          => 'Material Issue',
    'STOCK_TRANSFER_REQUEST'  => 'Stock Transfer Request',
    'STOCK_TRANSFER'          => 'Stock Transfer',
    'STOCK_RECEIPT'           => 'Stock Receipt',
    'STOCK_ADJUSTMENT'        => 'Stock Adjustment',
    'OPENING_STOCK'           => 'Opening Stock',
    'STOCK_COUNT'             => 'Stock Count',
    'STOCK_COUNT_REVIEW'      => 'Stock Count Review',
    'PRICE_MASTER'            => 'Sales Price Master',
    'SALES_INVOICE'           => 'Sales Invoice',
    'SALES_RETURN'            => 'Sales Return',
    'SALES_DELIVERY'          => 'Sales Delivery',
    'CASH_RECEIPT'            => 'Cash Receipt',
    _ => documentType,
  };
}
