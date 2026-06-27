class TaxGroupModel {
  final String?  id;
  final String   clientId;
  final String   companyId;
  final String   groupCode;
  final String   groupName;
  final String   applicableOn;   // SALES | PURCHASE | BOTH
  final String?  description;
  final int      sortOrder;
  final bool     isActive;
  final bool     isDeleted;

  const TaxGroupModel({
    this.id,
    required this.clientId,
    required this.companyId,
    required this.groupCode,
    required this.groupName,
    this.applicableOn = 'BOTH',
    this.description,
    this.sortOrder = 0,
    this.isActive  = true,
    this.isDeleted = false,
  });

  factory TaxGroupModel.fromJson(Map<String, dynamic> j) => TaxGroupModel(
    id:           j['id']            as String?,
    clientId:     j['client_id']     as String,
    companyId:    j['company_id']    as String,
    groupCode:    j['group_code']    as String,
    groupName:    j['group_name']    as String,
    applicableOn: j['applicable_on'] as String? ?? 'BOTH',
    description:  j['description']  as String?,
    sortOrder:    j['sort_order']    as int?    ?? 0,
    isActive:     j['is_active']     as bool?   ?? true,
    isDeleted:    j['is_deleted']    as bool?   ?? false,
  );

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    'client_id':    clientId,
    'company_id':   companyId,
    'group_code':   groupCode,
    'group_name':   groupName,
    'applicable_on': applicableOn,
    if (description != null) 'description': description,
    'sort_order':   sortOrder,
    'is_active':    isActive,
    'is_deleted':   isDeleted,
  };

  TaxGroupModel copyWith({
    String? groupCode,
    String? groupName,
    String? applicableOn,
    String? description,
    int?    sortOrder,
    bool?   isActive,
    bool?   isDeleted,
  }) =>
      TaxGroupModel(
        id:           id,
        clientId:     clientId,
        companyId:    companyId,
        groupCode:    groupCode    ?? this.groupCode,
        groupName:    groupName    ?? this.groupName,
        applicableOn: applicableOn ?? this.applicableOn,
        description:  description  ?? this.description,
        sortOrder:    sortOrder    ?? this.sortOrder,
        isActive:     isActive     ?? this.isActive,
        isDeleted:    isDeleted    ?? this.isDeleted,
      );
}
