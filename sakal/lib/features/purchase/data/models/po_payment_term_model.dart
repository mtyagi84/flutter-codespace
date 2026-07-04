/// rid_po_payment_terms. See backend/migrations/040_po_payment_terms_and_line_validation.sql.
/// termName is a frozen snapshot of the common-master label at save time —
/// description is the free-text detail entered per PO (e.g. "50% advance").
class PoPaymentTermModel {
  final String  id;
  final int     serialNo;
  final String  termId;
  final String  termName;
  final String? description;

  const PoPaymentTermModel({
    required this.id,
    required this.serialNo,
    required this.termId,
    required this.termName,
    this.description,
  });

  factory PoPaymentTermModel.fromJson(Map<String, dynamic> j) => PoPaymentTermModel(
    id:          j['id'] as String,
    serialNo:    j['serial_no'] as int,
    termId:      j['term_id'] as String,
    termName:    j['term_name'] as String,
    description: j['description'] as String?,
  );
}
