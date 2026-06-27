class TaxModel {
  final String?  id;
  final String   clientId;
  final String   companyId;
  final String   taxCode;
  final String   taxName;
  final String   taxTypeCode;
  final String   applicableOn;       // SALES | PURCHASE | BOTH
  final String   calculationType;    // PERCENTAGE | FIXED_AMOUNT | COMPOUND
  final bool     isPriceInclusive;
  final bool     isReverseCharge;
  final String?  glOutputAccountId;
  final String?  glInputAccountId;
  final String?  glExpenseAccountId;
  final int      sortOrder;
  final bool     isActive;
  final bool     isDeleted;

  const TaxModel({
    this.id,
    required this.clientId,
    required this.companyId,
    required this.taxCode,
    required this.taxName,
    required this.taxTypeCode,
    this.applicableOn    = 'BOTH',
    this.calculationType = 'PERCENTAGE',
    this.isPriceInclusive  = false,
    this.isReverseCharge   = false,
    this.glOutputAccountId,
    this.glInputAccountId,
    this.glExpenseAccountId,
    this.sortOrder = 0,
    this.isActive  = true,
    this.isDeleted = false,
  });

  factory TaxModel.fromJson(Map<String, dynamic> j) => TaxModel(
    id:                   j['id']                     as String?,
    clientId:             j['client_id']              as String,
    companyId:            j['company_id']             as String,
    taxCode:              j['tax_code']               as String,
    taxName:              j['tax_name']               as String,
    taxTypeCode:          j['tax_type_code']          as String,
    applicableOn:         j['applicable_on']          as String? ?? 'BOTH',
    calculationType:      j['calculation_type']       as String? ?? 'PERCENTAGE',
    isPriceInclusive:     j['is_price_inclusive']     as bool?   ?? false,
    isReverseCharge:      j['is_reverse_charge']      as bool?   ?? false,
    glOutputAccountId:    j['gl_output_account_id']   as String?,
    glInputAccountId:     j['gl_input_account_id']    as String?,
    glExpenseAccountId:   j['gl_expense_account_id']  as String?,
    sortOrder:            j['sort_order']             as int?    ?? 0,
    isActive:             j['is_active']              as bool?   ?? true,
    isDeleted:            j['is_deleted']             as bool?   ?? false,
  );

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    'client_id':           clientId,
    'company_id':          companyId,
    'tax_code':            taxCode,
    'tax_name':            taxName,
    'tax_type_code':       taxTypeCode,
    'applicable_on':       applicableOn,
    'calculation_type':    calculationType,
    'is_price_inclusive':  isPriceInclusive,
    'is_reverse_charge':   isReverseCharge,
    if (glOutputAccountId  != null) 'gl_output_account_id':  glOutputAccountId,
    if (glInputAccountId   != null) 'gl_input_account_id':   glInputAccountId,
    if (glExpenseAccountId != null) 'gl_expense_account_id': glExpenseAccountId,
    'sort_order':          sortOrder,
    'is_active':           isActive,
    'is_deleted':          isDeleted,
  };

  TaxModel copyWith({
    String? id,
    String? taxCode,
    String? taxName,
    String? taxTypeCode,
    String? applicableOn,
    String? calculationType,
    bool?   isPriceInclusive,
    bool?   isReverseCharge,
    String? glOutputAccountId,
    String? glInputAccountId,
    String? glExpenseAccountId,
    int?    sortOrder,
    bool?   isActive,
    bool?   isDeleted,
  }) =>
      TaxModel(
        id:                    id                   ?? this.id,
        clientId:              clientId,
        companyId:             companyId,
        taxCode:               taxCode              ?? this.taxCode,
        taxName:               taxName              ?? this.taxName,
        taxTypeCode:           taxTypeCode          ?? this.taxTypeCode,
        applicableOn:          applicableOn         ?? this.applicableOn,
        calculationType:       calculationType      ?? this.calculationType,
        isPriceInclusive:      isPriceInclusive     ?? this.isPriceInclusive,
        isReverseCharge:       isReverseCharge      ?? this.isReverseCharge,
        glOutputAccountId:     glOutputAccountId    ?? this.glOutputAccountId,
        glInputAccountId:      glInputAccountId     ?? this.glInputAccountId,
        glExpenseAccountId:    glExpenseAccountId   ?? this.glExpenseAccountId,
        sortOrder:             sortOrder            ?? this.sortOrder,
        isActive:              isActive             ?? this.isActive,
        isDeleted:             isDeleted            ?? this.isDeleted,
      );
}
