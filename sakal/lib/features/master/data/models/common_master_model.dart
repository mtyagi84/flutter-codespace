class CommonMasterModel {
  final String  id;
  final String  clientId;
  final String  companyId;
  final String  typeId;
  final String  description;
  final String? shortName;
  final int     sortOrder;
  final bool    isActive;
  final bool    isDeleted;

  const CommonMasterModel({
    required this.id,
    required this.clientId,
    required this.companyId,
    required this.typeId,
    required this.description,
    this.shortName,
    required this.sortOrder,
    required this.isActive,
    required this.isDeleted,
  });

  factory CommonMasterModel.fromJson(Map<String, dynamic> j) =>
      CommonMasterModel(
        id:          j['id']          as String,
        clientId:    j['client_id']   as String,
        companyId:   j['company_id']  as String,
        typeId:      j['type_id']     as String,
        description: j['description'] as String,
        shortName:   j['short_name']  as String?,
        sortOrder:   j['sort_order']  as int? ?? 0,
        isActive:    j['is_active']   as bool? ?? true,
        isDeleted:   j['is_deleted']  as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id':          id,
        'client_id':   clientId,
        'company_id':  companyId,
        'type_id':     typeId,
        'description': description,
        if (shortName != null) 'short_name': shortName,
        'sort_order':  sortOrder,
        'is_active':   isActive,
        'is_deleted':  isDeleted,
      };

  CommonMasterModel copyWith({
    String?  description,
    String?  shortName,
    int?     sortOrder,
    bool?    isActive,
    bool?    isDeleted,
  }) =>
      CommonMasterModel(
        id:          id,
        clientId:    clientId,
        companyId:   companyId,
        typeId:      typeId,
        description: description ?? this.description,
        shortName:   shortName   ?? this.shortName,
        sortOrder:   sortOrder   ?? this.sortOrder,
        isActive:    isActive    ?? this.isActive,
        isDeleted:   isDeleted   ?? this.isDeleted,
      );
}
