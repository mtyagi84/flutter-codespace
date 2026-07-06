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

  /// Every scalar field (usable by text/field/image/barcode/watermark
  /// elements) available for a document type, company fields included.
  static List<PrintFieldDef> scalarFields(String documentType) => [
    ...switch (documentType) {
      'PURCHASE_ORDER'   => _poScalarFields,
      'GRN'              => _grnScalarFields,
      'PURCHASE_INVOICE' => _purchaseInvoiceScalarFields,
      'PURCHASE_RETURN'  => _purchaseReturnScalarFields,
      'VOUCHER'          => _voucherScalarFields,
      _ => const <PrintFieldDef>[],
    },
    ..._companyFields,
  ];

  /// Which repeating lists (table `bind` values) exist for a document type.
  static List<String> tableNames(String documentType) => switch (documentType) {
    'PURCHASE_ORDER'   => const ['lines', 'charges', 'paymentTerms'],
    'GRN'              => const ['lines', 'charges'],
    'PURCHASE_INVOICE' => const ['grns'],
    'PURCHASE_RETURN'  => const ['lines'],
    'VOUCHER'          => const ['lines'],
    _ => const [],
  };

  /// Columns available for a table bound to [tableName] within [documentType].
  static List<PrintFieldDef> rowFields(String documentType, String tableName) => switch (documentType) {
    'PURCHASE_ORDER'   => _poTableRowFields[tableName] ?? const [],
    'GRN'              => _grnTableRowFields[tableName] ?? const [],
    'PURCHASE_INVOICE' => _purchaseInvoiceTableRowFields[tableName] ?? const [],
    'PURCHASE_RETURN'  => _purchaseReturnTableRowFields[tableName] ?? const [],
    'VOUCHER'          => _voucherTableRowFields[tableName] ?? const [],
    _ => const [],
  };

  /// Document types the designer currently knows how to edit. Matches
  /// print_template_provider.dart's fallback registry — add a new type to
  /// both places (plus a *_default_template.dart and field entries here)
  /// when a new document's print support is built.
  static const documentTypes = ['PURCHASE_ORDER', 'GRN', 'PURCHASE_INVOICE', 'PURCHASE_RETURN', 'VOUCHER'];

  static String documentTypeLabel(String documentType) => switch (documentType) {
    'PURCHASE_ORDER'   => 'Purchase Order',
    'GRN'              => 'Goods Receipt Note',
    'PURCHASE_INVOICE' => 'Purchase Bill',
    'PURCHASE_RETURN'  => 'Purchase Return',
    'VOUCHER'          => 'Finance Voucher',
    _ => documentType,
  };
}
