import '../../data/models/finance_voucher_model.dart';

abstract class FinanceVoucherRepository {
  Future<FinanceVoucherHeader?> getHeader({
    required String clientId,
    required String companyId,
    required String transNo,
    String? transDate,
  });

  Future<List<FinanceVoucherLine>> getLines({
    required String clientId,
    required String companyId,
    required String transNo,
    required String transDate,
  });

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required String userId,
  });

  Future<void> post({
    required String clientId,
    required String companyId,
    required String locationId,
    required String transNo,
    required String transDate,
    required String postedBy,
  });

  Future<List<Map<String, dynamic>>> getPendingBills({
    required String companyId,
    required String locationId,
    required String accountId,
  });

  Future<double?> fetchExchangeRate({
    required String companyId,
    required String locationId,
    required String fromCurrency,
    required String toCurrency,
    required String rateDate,
  });
}
