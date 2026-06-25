class CommonMasterTypeModel {
  final String id;
  final String typeKey;
  final String typeName;
  final bool   isActive;

  const CommonMasterTypeModel({
    required this.id,
    required this.typeKey,
    required this.typeName,
    required this.isActive,
  });

  factory CommonMasterTypeModel.fromJson(Map<String, dynamic> j) =>
      CommonMasterTypeModel(
        id:       j['id']        as String,
        typeKey:  j['type_key']  as String,
        typeName: j['type_name'] as String,
        isActive: j['is_active'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        'id':        id,
        'type_key':  typeKey,
        'type_name': typeName,
        'is_active': isActive,
      };
}
