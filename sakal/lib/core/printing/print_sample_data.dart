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
    'SALES_QUOTATION' => {
      'company': _company(),
      'header': {
        'quotation_no':      'SQ/KIN/2026/00001',
        'quotation_date':    '10 Jul 2026',
        'valid_until_date':  '25 Jul 2026',
        'status':            'DRAFT',
        'customer_name':     '[3110] Sample Customer Ltd',
        'sales_person_name': 'John Sales',
        'currency_code':     'USD',
        'payment_terms':     '30 days net',
        'delivery_terms':    'Ex-Warehouse, Lubumbashi',
        'remarks':           'Sample remarks for preview.',
      },
      'lines': [
        {'product_name': 'Sample Item A', 'uom_label': 'Piece', 'base_qty': 10, 'rate': 30.0, 'final_amount': 300.0},
        {'product_name': 'Sample Item B', 'uom_label': 'Carton', 'base_qty': 2, 'rate': 140.0, 'final_amount': 280.0},
      ],
      'charges': [
        {'charge_name': 'Delivery', 'amount': 20.0},
      ],
      'totals': {
        'gross_amount': 580.0,
        'discount_amount': 0.0,
        'tax_amount': 92.8,
        'charges_amount': 20.0,
        'grand_total': 692.8,
      },
    },
    'SALES_ORDER' => {
      'company': _company(),
      'header': {
        'order_no':          'SO/KIN/2026/00001',
        'order_date':        '12 Jul 2026',
        'order_mode':        'Direct',
        'source_quotation':  '',
        'status':            'DRAFT',
        'customer_name':     '[3110] Sample Customer Ltd',
        'customer_po_ref':   'PO-2026-0456',
        'ship_to':           'Sample Customer Ltd, Warehouse 2, Lubumbashi',
        'bill_to':           'Sample Customer Ltd, Head Office, Lubumbashi',
        'expected_delivery_date': '20 Jul 2026',
        'sales_person_name': 'John Sales',
        'currency_code':     'USD',
        'payment_term_name': '30% Advance, 70% in 30 Days',
        'incoterm_label':    'Ex-Works (EXW)',
        'delivery_instructions': 'Deliver during business hours only.',
        'remarks':           'Sample remarks for preview.',
      },
      'lines': [
        {'product_name': 'Sample Item A', 'uom_label': 'Piece', 'base_qty': 10, 'rate': 30.0, 'final_amount': 300.0},
        {'product_name': 'Sample Item B', 'uom_label': 'Carton', 'base_qty': 2, 'rate': 140.0, 'final_amount': 280.0},
      ],
      'charges': [
        {'charge_name': 'Delivery', 'amount': 20.0},
      ],
      'totals': {
        'gross_amount': 580.0,
        'discount_amount': 0.0,
        'tax_amount': 92.8,
        'charges_amount': 20.0,
        'grand_total': 692.8,
      },
    },
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
    'OPENING_STOCK' => {
      'company': _company(),
      'header': {
        'opening_no':    'OPST/2026/00001',
        'opening_date':  '10 Jul 2026',
        'status':        'DRAFT',
        'location_name': 'Main Warehouse',
        'remarks':       'Sample remarks for preview.',
      },
      'lines': [
        {'product_name': 'Sample Item A', 'batch_no': '', 'serial_no': '', 'base_qty': 20, 'unit_cost': 5.0, 'amount': 100.0},
        {'product_name': 'Sample Item B', 'batch_no': 'B001', 'serial_no': '', 'base_qty': 6, 'unit_cost': 8.0, 'amount': 48.0},
      ],
    },
    'STOCK_COUNT' => {
      'company': _company(),
      'header': {
        'count_no':      'CNT/2026/00001',
        'count_date':    '10 Jul 2026',
        'status':        'SUBMITTED',
        'location_name': 'Main Warehouse',
        'category':      'Grocery › Snacks',
        'remarks':       'Sample remarks for preview.',
      },
      'lines': [
        {'product_name': 'Sample Item A', 'counted_qty': 42},
        {'product_name': 'Sample Item B', 'counted_qty': 15},
      ],
    },
    'STOCK_COUNT_REVIEW' => {
      'company': _company(),
      'header': {
        'review_no':             'CNTR/2026/00001',
        'review_date':           '11 Jul 2026',
        'as_of_date':            '10 Jul 2026',
        'status':                'APPROVED',
        'location_name':         'Main Warehouse',
        'posted_adjustment_no':  'ADJ/2026/00003',
        'remarks':               'Sample remarks for preview.',
      },
      'lines': [
        {'product_name': 'Sample Item A', 'batch_no': '', 'serial_no': '', 'counted_qty': 42, 'system_qty': 40, 'variance_qty': 2, 'adjust_flag': '+'},
        {'product_name': 'Sample Item B', 'batch_no': 'B001', 'serial_no': '', 'counted_qty': 15, 'system_qty': 18, 'variance_qty': -3, 'adjust_flag': '-'},
      ],
    },
    'PRICE_MASTER' => {
      'company': _company(),
      'header': {
        'entry_no':         'PRC/KIN/2026/00001',
        'entry_date':       '10 Jul 2026',
        'effective_date':   '01 Aug 2026',
        'status':           'DRAFT',
        'location_name':    'Main Warehouse',
        'price_type_label': 'Generic',
        'customer_name':    '',
        'currency_code':    'USD',
        'remarks':          'Sample remarks for preview.',
      },
      'lines': [
        {'product_name': 'Sample Item A', 'uom_label': 'Piece', 'cost_price': 5.0, 'margin_percent': 20.0, 'selling_price': 6.0},
        {'product_name': 'Sample Item B', 'uom_label': 'Carton', 'cost_price': 40.0, 'margin_percent': 12.5, 'selling_price': 45.0},
      ],
    },
    'SALES_INVOICE' => {
      'company': _company(),
      'header': {
        'invoice_no':        'SI/KIN/2026/00001',
        'invoice_date':      '16 Jul 2026',
        'provisional':       false,
        'sale_type':         'CASH',
        'status':            'APPROVED',
        'customer_name':     'Walk-in Customer',
        'party_phone':       '+243 900 000 000',
        'party_address':     'Lubumbashi, DRC',
        'sales_person_name': 'John Sales',
        'currency_code':     'USD',
        'remarks':           'Sample remarks for preview.',
      },
      'lines': [
        {'product_name': 'Sample Item A', 'uom_label': 'Piece', 'base_qty': 5, 'rate': 30.0, 'final_amount': 150.0},
        {'product_name': 'Sample Item B', 'uom_label': 'Carton', 'base_qty': 1, 'rate': 140.0, 'final_amount': 140.0},
      ],
      'charges': [
        {'charge_name': 'Delivery', 'amount': 10.0},
      ],
      'totals': {
        'gross_amount': 290.0,
        'discount_amount': 0.0,
        'charges_amount': 10.0,
        'tax_amount': 47.4,
        'grand_total': 347.4,
      },
    },
    _ => {'company': _company(), 'header': {}, 'lines': [], 'totals': {}},
  };
}
