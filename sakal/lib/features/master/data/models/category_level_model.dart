class CategoryLevelModel {
  final String? id;
  final String  clientId;
  final String  companyId;
  final int     levelNo;
  final String  levelLabel;
  final bool    isMandatory;
  final bool    isActive;

  const CategoryLevelModel({
    this.id,
    required this.clientId,
    required this.companyId,
    required this.levelNo,
    required this.levelLabel,
    required this.isMandatory,
    required this.isActive,
  });

  factory CategoryLevelModel.fromJson(Map<String, dynamic> j) =>
      CategoryLevelModel(
        id:          j['id']           as String?,
        clientId:    j['client_id']    as String,
        companyId:   j['company_id']   as String,
        levelNo:     j['level_no']     as int,
        levelLabel:  j['level_label']  as String,
        isMandatory: j['is_mandatory'] as bool? ?? false,
        isActive:    j['is_active']    as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'client_id':    clientId,
        'company_id':   companyId,
        'level_no':     levelNo,
        'level_label':  levelLabel,
        'is_mandatory': isMandatory,
        'is_active':    isActive,
        'sort_order':   levelNo,
      };

  CategoryLevelModel copyWith({String? levelLabel, bool? isMandatory, bool? isActive}) =>
      CategoryLevelModel(
        id:          id,
        clientId:    clientId,
        companyId:   companyId,
        levelNo:     levelNo,
        levelLabel:  levelLabel  ?? this.levelLabel,
        isMandatory: isMandatory ?? this.isMandatory,
        isActive:    isActive    ?? this.isActive,
      );
}
