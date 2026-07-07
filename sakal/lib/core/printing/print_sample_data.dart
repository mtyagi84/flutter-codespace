/// Placeholder document data for the template designer's Preview button —
/// lets an admin see roughly how a template will look without needing a
/// real saved document on hand. Deliberately NOT wired to any live data;
/// keep in sync with the field bindings in print_field_registry.dart.
class PrintSampleData {
  PrintSampleData._();

  static Map<String, dynamic> _company() => {
    'company_name': 'Rigvedam Innovations',
    'address':      '123 Example Street',
    'city_name':    'Lubumbashi, DRC',
    'logo':         null,
  };

  static Map<String, dynamic> forDocumentType(String documentType) => switch (documentType) {
    'PURCHASE_ORDER' => {
      'company': _company(),
      'header': {
        'order_no':      'PO/2026/00001',
        'order_date':    '10 Jul 2026',
        'status':        'DRAFT',
        'supplier_name': '[2110] Sample Supplier Ltd',
        'buyer_name':    'Jane Buyer',
        'currency_code': 'USD',
        'po_type':       'LOCAL',
        'bill_to':       'Head Office, Lubumbashi',
        'ship_to':       'Main Warehouse, Lubumbashi',
        'remarks':       'Sample remarks for preview.',
      },
      'lines': [
        {'product_name': 'Sample Item A', 'uom_label': 'Piece', 'base_qty': 10, 'rate': 25.5, 'final_amount': 255.0},
        {'product_name': 'Sample Item B', 'uom_label': 'Carton', 'base_qty': 2, 'rate': 120.0, 'final_amount': 240.0},
      ],
      'charges': [
        {'charge_name': 'Freight', 'amount': 30.0},
      ],
      'paymentTerms': [
        {'term_name': 'Credit 30 Days', 'description': '30 days from GRN date'},
      ],
      'totals': {
        'gross_amount': 495.0,
        'discount_amount': 0.0,
        'item_tax_amount': 79.2,
        'charges_amount': 30.0,
        'grand_total': 604.2,
      },
    },
    'GRN' => {
      'company': _company(),
      'header': {
        'grn_no':               'GRN/2026/00001',
        'grn_date':             '10 Jul 2026',
        'status':               'DRAFT',
        'receipt_mode':         'Against PO',
        'supplier_name':        '[2110] Sample Supplier Ltd',
        'currency_code':        'USD',
        'supplier_delivery_no': 'DN-4521',
        'bill_to':              'Head Office, Lubumbashi',
        'ship_to':              'Main Warehouse, Lubumbashi',
        'remarks':              'Sample remarks for preview.',
      },
      'lines': [
        {'product_name': 'Sample Item A', 'uom_label': 'Piece', 'base_qty': 10, 'rate': 25.5, 'final_amount': 255.0},
        {'product_name': 'Sample Item B', 'uom_label': 'Carton', 'base_qty': 2, 'rate': 120.0, 'final_amount': 240.0},
      ],
      'charges': [
        {'charge_name': 'Freight', 'amount': 30.0},
      ],
      'totals': {
        'gross_amount': 495.0,
        'discount_amount': 0.0,
        'item_tax_amount': 79.2,
        'charges_amount': 30.0,
        'grand_total': 604.2,
      },
    },
    'VOUCHER' => {
      'company': _company(),
      'header': {
        'voucher_type_label': 'CASH RECEIPT VOUCHER',
        'voucher_no':         'CRV/2026/00001',
        'trans_date':         '10 Jul 2026',
        'cash_bank_account':  '[1000] Cash Account',
        'payment_mode':       'Cash',
        'ref_no':             '',
        'currency_line':      '',
        'remarks':            'Sample remarks for preview.',
        'is_on_account_str':  'true',
        'party_name':         '',
      },
      'lines': [
        {'particulars': 'Sample Customer A/c', 'amount': 500.0, 'party_amount': '—', 'remarks': ''},
      ],
      'totals': {'total_display': '500.00 USD'},
      'signatures': {'prepared_by': 'Jane Buyer', 'authorised_by': ''},
    },
    'MATERIAL_REQUISITION' => {
      'company': _company(),
      'header': {
        'requisition_no':   'MREQ/2026/00001',
        'requisition_date': '10 Jul 2026',
        'status':           'DRAFT',
        'location_name':    'Main Warehouse',
        'requested_by':     'Jane Buyer',
        'reason':           'Monthly consumable top-up',
        'remarks':          'Sample remarks for preview.',
      },
      'lines': [
        {'product_name': 'Sample Item A', 'uom_label': 'Piece', 'base_qty': 10, 'department_name': 'Production', 'area_name': 'Assembly Line 1'},
        {'product_name': 'Sample Item B', 'uom_label': 'Carton', 'base_qty': 2, 'department_name': 'Production', 'area_name': 'Assembly Line 1'},
      ],
    },
    'MATERIAL_ISSUE' => {
      'company': _company(),
      'header': {
        'issue_no':      'MISS/2026/00001',
        'issue_date':    '10 Jul 2026',
        'status':        'DRAFT',
        'location_name': 'Main Warehouse',
        'remarks':       'Sample remarks for preview.',
      },
      'lines': [
        {'product_name': 'Sample Item A', 'source_requisition_no': 'MREQ/2026/00001', 'issue_qty': 10, 'department_name': 'Production', 'area_name': 'Assembly Line 1'},
      ],
    },
    'STOCK_TRANSFER_REQUEST' => {
      'company': _company(),
      'header': {
        'request_no':        'STRQ/2026/00001',
        'request_date':      '10 Jul 2026',
        'status':            'DRAFT',
        'from_location_name': 'Main Warehouse',
        'to_location_name':   'Shop Floor',
        'remarks':            'Sample remarks for preview.',
      },
      'lines': [
        {'product_name': 'Sample Item A', 'uom_label': 'Piece', 'base_qty': 10, 'remarks': ''},
      ],
    },
    'STOCK_TRANSFER' => {
      'company': _company(),
      'header': {
        'transfer_no':        'STXF/2026/00001',
        'transfer_date':      '10 Jul 2026',
        'status':             'DRAFT',
        'from_location_name': 'Main Warehouse',
        'to_location_name':   'Shop Floor',
        'mode_label':         'Direct',
        'remarks':            'Sample remarks for preview.',
      },
      'lines': [
        {'product_name': 'Sample Item A', 'base_qty': 10, 'unit_value': 10.0, 'charge_amount': 15.0},
      ],
      'charges': [
        {'charge_name': 'Freight', 'amount': 15.0},
      ],
      'totals': {'charges_amount': 15.0},
    },
    'STOCK_RECEIPT' => {
      'company': _company(),
      'header': {
        'receipt_no':          'SRCP/2026/00001',
        'receipt_date':        '10 Jul 2026',
        'status':              'DRAFT',
        'source_transfer_no':  'STXF/2026/00001',
        'from_location_name':  'Main Warehouse',
        'to_location_name':    'Shop Floor',
        'remarks':             'Sample remarks for preview.',
      },
      'lines': [
        {'product_name': 'Sample Item A', 'dispatched_qty': 10, 'received_qty': 9, 'shortfall_qty': 1},
      ],
    },
    'STOCK_ADJUSTMENT' => {
      'company': _company(),
      'header': {
        'adjustment_no':   'ADJ/2026/00001',
        'adjustment_date': '10 Jul 2026',
        'status':          'DRAFT',
        'location_name':   'Main Warehouse',
        'reason':          'Physical Count Variance',
        'remarks':         'Sample remarks for preview.',
      },
      'lines': [
        {'product_name': 'Sample Item A', 'direction': 'Increase', 'base_qty': 5, 'system_qty': 45},
        {'product_name': 'Sample Item B', 'direction': 'Decrease', 'base_qty': 2, 'system_qty': 20},
      ],
    },
    _ => {'company': _company(), 'header': {}, 'lines': [], 'totals': {}},
  };
}
