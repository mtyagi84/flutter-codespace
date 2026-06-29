class ProductFlagTypeModel {
  final String? id;
  final String  clientId;
  final String  companyId;
  final String  flagKey;
  final String  flagLabel;
  final bool    defaultValue;
  final String? description;
  final int     sortOrder;
  final bool    isActive;

  const ProductFlagTypeModel({
    this.id,
    required this.clientId,
    required this.companyId,
    required this.flagKey,
    required this.flagLabel,
    required this.defaultValue,
    this.description,
    required this.sortOrder,
    required this.isActive,
  });

  factory ProductFlagTypeModel.fromJson(Map<String, dynamic> j) =>
      ProductFlagTypeModel(
        id:           j['id']            as String?,
        clientId:     j['client_id']     as String,
        companyId:    j['company_id']    as String,
        flagKey:      j['flag_key']      as String,
        flagLabel:    j['flag_label']    as String,
        defaultValue: j['default_value'] as bool? ?? true,
        description:  j['description']   as String?,
        sortOrder:    j['sort_order']    as int? ?? 0,
        isActive:     j['is_active']     as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'client_id':     clientId,
        'company_id':    companyId,
        'flag_key':      flagKey,
        'flag_label':    flagLabel,
        'default_value': defaultValue,
        if (description != null) 'description': description,
        'sort_order':    sortOrder,
        'is_active':     isActive,
      };

  ProductFlagTypeModel copyWith({
    String? flagLabel,
    bool?   defaultValue,
    String? description,
    int?    sortOrder,
    bool?   isActive,
  }) =>
      ProductFlagTypeModel(
        id:           id,
        clientId:     clientId,
        companyId:    companyId,
        flagKey:      flagKey,
        flagLabel:    flagLabel    ?? this.flagLabel,
        defaultValue: defaultValue ?? this.defaultValue,
        description:  description  ?? this.description,
        sortOrder:    sortOrder    ?? this.sortOrder,
        isActive:     isActive     ?? this.isActive,
      );

  // Standard flags seeded via "Load Defaults" button.
  // Flags are shared by both rim_item_categories and rim_products (same JSONB pattern).
  static List<Map<String, dynamic>> defaults({
    required String clientId,
    required String companyId,
  }) =>
      [
        {'client_id': clientId, 'company_id': companyId, 'flag_key': 'is_saleable',          'flag_label': 'Can be Sold',                  'default_value': true,  'sort_order': 1},
        {'client_id': clientId, 'company_id': companyId, 'flag_key': 'is_purchasable',       'flag_label': 'Can be Purchased',              'default_value': true,  'sort_order': 2},
        {'client_id': clientId, 'company_id': companyId, 'flag_key': 'is_pos_item',          'flag_label': 'Appears on POS Screen',         'default_value': true,  'sort_order': 3},
        {'client_id': clientId, 'company_id': companyId, 'flag_key': 'is_discountable',      'flag_label': 'Discount Allowed',              'default_value': true,  'sort_order': 4},
        {'client_id': clientId, 'company_id': companyId, 'flag_key': 'is_transferable',      'flag_label': 'Warehouse Transfer Allowed',    'default_value': true,  'sort_order': 5},
        {'client_id': clientId, 'company_id': companyId, 'flag_key': 'is_intercompany',      'flag_label': 'Intercompany Transfer Allowed', 'default_value': false, 'sort_order': 6},
        {'client_id': clientId, 'company_id': companyId, 'flag_key': 'allow_negative_stock', 'flag_label': 'Allow Negative Stock',          'default_value': false, 'sort_order': 7},
        {'client_id': clientId, 'company_id': companyId, 'flag_key': 'is_consignment',       'flag_label': 'Consignment Stock',             'default_value': false, 'sort_order': 8},
      ];
}
