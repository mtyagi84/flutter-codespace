class FinanceVoucherHeader {
  final String  clientId;
  final String  companyId;
  final String  locationId;
  final String  transNo;
  final String  transDate;
  final String  voucherTypeCode;
  final String  paymentModeCode;
  final bool    isOnAccount;
  final String  referenceNo;
  final String  referenceDate;
  final String  chequeNo;
  final String  chequeDate;
  final String  remarks;
  final bool    isPosted;
  final bool    isDeleted;

  const FinanceVoucherHeader({
    required this.clientId,
    required this.companyId,
    required this.locationId,
    required this.transNo,
    required this.transDate,
    required this.voucherTypeCode,
    required this.paymentModeCode,
    required this.isOnAccount,
    required this.referenceNo,
    required this.referenceDate,
    required this.chequeNo,
    required this.chequeDate,
    required this.remarks,
    required this.isPosted,
    required this.isDeleted,
  });

  factory FinanceVoucherHeader.fromJson(Map<String, dynamic> j) =>
      FinanceVoucherHeader(
        clientId:        j['client_id']          as String? ?? '',
        companyId:       j['company_id']         as String? ?? '',
        locationId:      j['location_id']        as String? ?? '',
        transNo:         j['trans_no']           as String? ?? '',
        transDate:       j['trans_date']         as String? ?? '',
        voucherTypeCode: j['voucher_type_code']  as String? ?? '',
        paymentModeCode: j['payment_mode_code']  as String? ?? '',
        isOnAccount:     j['is_on_account']      as bool?   ?? false,
        referenceNo:     j['reference_no']       as String? ?? '',
        referenceDate:   j['reference_date']     as String? ?? '',
        chequeNo:        j['cheque_no']          as String? ?? '',
        chequeDate:      j['cheque_date']        as String? ?? '',
        remarks:         j['remarks']            as String? ?? '',
        isPosted:        j['is_posted']          as bool?   ?? false,
        isDeleted:       j['is_deleted']         as bool?   ?? false,
      );

  Map<String, dynamic> toJson() => {
    'client_id':          clientId,
    'company_id':         companyId,
    'location_id':        locationId,
    'trans_no':           transNo,
    'trans_date':         transDate,
    'voucher_type_code':  voucherTypeCode,
    'payment_mode_code':  paymentModeCode,
    'is_on_account':      isOnAccount,
    'reference_no':       referenceNo,
    'reference_date':     referenceDate,
    'cheque_no':          chequeNo,
    'cheque_date':        chequeDate,
    'remarks':            remarks,
  };
}

class FinanceVoucherLine {
  final int    serialNo;
  final String accountId;
  final String transNature;
  final double transAmount;
  final String transCurrency;
  final double baseAmount;
  final double baseRate;
  final double localAmount;
  final double localRate;
  final double partyAmount;
  final String partyCurrency;
  final double partyRate;
  final String invBillNo;
  final String invBillDate;
  final String lineRemarks;

  const FinanceVoucherLine({
    required this.serialNo,
    required this.accountId,
    required this.transNature,
    required this.transAmount,
    required this.transCurrency,
    required this.baseAmount,
    required this.baseRate,
    required this.localAmount,
    required this.localRate,
    required this.partyAmount,
    required this.partyCurrency,
    required this.partyRate,
    required this.invBillNo,
    required this.invBillDate,
    required this.lineRemarks,
  });

  factory FinanceVoucherLine.fromJson(Map<String, dynamic> j) =>
      FinanceVoucherLine(
        serialNo:      (j['serial_no']      as num? ?? 0).toInt(),
        accountId:      j['account_id']     as String? ?? '',
        transNature:    j['trans_nature']   as String? ?? '',
        transAmount:   (j['trans_amount']   as num? ?? 0).toDouble(),
        transCurrency:  j['trans_currency'] as String? ?? '',
        baseAmount:    (j['base_amount']    as num? ?? 0).toDouble(),
        baseRate:      (j['base_rate']      as num? ?? 1).toDouble(),
        localAmount:   (j['local_amount']   as num? ?? 0).toDouble(),
        localRate:     (j['local_rate']     as num? ?? 1).toDouble(),
        partyAmount:   (j['party_amount']   as num? ?? 0).toDouble(),
        partyCurrency:  j['party_currency'] as String? ?? '',
        partyRate:     (j['party_rate']     as num? ?? 1).toDouble(),
        invBillNo:      j['inv_bill_no']    as String? ?? '',
        invBillDate:    j['inv_bill_date']  as String? ?? '',
        lineRemarks:    j['line_remarks']   as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
    'serial_no':      serialNo,
    'account_id':     accountId,
    'trans_nature':   transNature,
    'trans_amount':   transAmount,
    'trans_currency': transCurrency,
    'base_amount':    baseAmount,
    'base_rate':      baseRate,
    'local_amount':   localAmount,
    'local_rate':     localRate,
    'party_amount':   partyAmount,
    'party_currency': partyCurrency,
    'party_rate':     partyRate,
    'inv_bill_no':    invBillNo,
    'inv_bill_date':  invBillDate,
    'line_remarks':   lineRemarks,
  };
}
