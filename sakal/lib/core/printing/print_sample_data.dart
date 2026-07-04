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
    _ => {'company': _company(), 'header': {}, 'lines': [], 'totals': {}},
  };
}
