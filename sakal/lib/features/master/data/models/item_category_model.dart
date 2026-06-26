class ItemCategoryModel {
  final String? id;
  final String  clientId;
  final String  companyId;
  final String? parentId;
  final int     levelNo;
  final String  categoryName;
  final String? categoryShort;
  final int     sortOrder;
  final bool    isActive;
  final bool    isDeleted;

  // Populated client-side when building tree
  final List<ItemCategoryModel> children;

  const ItemCategoryModel({
    this.id,
    required this.clientId,
    required this.companyId,
    this.parentId,
    required this.levelNo,
    required this.categoryName,
    this.categoryShort,
    required this.sortOrder,
    required this.isActive,
    required this.isDeleted,
    this.children = const [],
  });

  factory ItemCategoryModel.fromJson(Map<String, dynamic> j) =>
      ItemCategoryModel(
        id:            j['id']             as String?,
        clientId:      j['client_id']      as String,
        companyId:     j['company_id']     as String,
        parentId:      j['parent_id']      as String?,
        levelNo:       j['level_no']       as int,
        categoryName:  j['category_name']  as String,
        categoryShort: j['category_short'] as String?,
        sortOrder:     j['sort_order']     as int? ?? 0,
        isActive:      j['is_active']      as bool? ?? true,
        isDeleted:     j['is_deleted']     as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'client_id':      clientId,
        'company_id':     companyId,
        if (parentId != null) 'parent_id': parentId,
        'level_no':       levelNo,
        'category_name':  categoryName,
        if (categoryShort != null) 'category_short': categoryShort,
        'sort_order':     sortOrder,
        'is_active':      isActive,
        'is_deleted':     isDeleted,
      };
}
