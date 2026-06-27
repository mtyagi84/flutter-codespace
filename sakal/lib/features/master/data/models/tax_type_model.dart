class TaxTypeModel {
  final String id;
  final String taxTypeCode;
  final String typeName;
  final bool   isWithholding;
  final int    sortOrder;
  final bool   isActive;

  const TaxTypeModel({
    required this.id,
    required this.taxTypeCode,
    required this.typeName,
    required this.isWithholding,
    required this.sortOrder,
    required this.isActive,
  });

  factory TaxTypeModel.fromJson(Map<String, dynamic> j) => TaxTypeModel(
    id:            j['id']             as String,
    taxTypeCode:   j['tax_type_code']  as String,
    typeName:      j['type_name']      as String,
    isWithholding: j['is_withholding'] as bool? ?? false,
    sortOrder:     j['sort_order']     as int?  ?? 0,
    isActive:      j['is_active']      as bool? ?? true,
  );
}
