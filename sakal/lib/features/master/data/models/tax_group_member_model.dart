class TaxGroupMemberModel {
  final String? id;
  final String  clientId;
  final String  companyId;
  final String  taxGroupId;
  final String  taxId;
  final int     sequenceNo;

  // Client-side resolved display (not stored)
  final String taxCode;
  final String taxName;

  const TaxGroupMemberModel({
    this.id,
    required this.clientId,
    required this.companyId,
    required this.taxGroupId,
    required this.taxId,
    required this.sequenceNo,
    this.taxCode = '',
    this.taxName = '',
  });

  factory TaxGroupMemberModel.fromJson(Map<String, dynamic> j) =>
      TaxGroupMemberModel(
        id:          j['id']           as String?,
        clientId:    j['client_id']    as String,
        companyId:   j['company_id']   as String,
        taxGroupId:  j['tax_group_id'] as String,
        taxId:       j['tax_id']       as String,
        sequenceNo:  j['sequence_no']  as int? ?? 1,
      );

  Map<String, dynamic> toRpcJson() => {
    'tax_id':      taxId,
    'sequence_no': sequenceNo,
  };

  TaxGroupMemberModel withDisplay({required String code, required String name}) =>
      TaxGroupMemberModel(
        id:         id,
        clientId:   clientId,
        companyId:  companyId,
        taxGroupId: taxGroupId,
        taxId:      taxId,
        sequenceNo: sequenceNo,
        taxCode:    code,
        taxName:    name,
      );

  TaxGroupMemberModel copyWith({int? sequenceNo}) =>
      TaxGroupMemberModel(
        id:         id,
        clientId:   clientId,
        companyId:  companyId,
        taxGroupId: taxGroupId,
        taxId:      taxId,
        sequenceNo: sequenceNo ?? this.sequenceNo,
        taxCode:    taxCode,
        taxName:    taxName,
      );
}
