import '../../domain/repositories/finance_voucher_repository.dart';
import '../datasources/finance_voucher_remote_ds.dart';
import '../models/finance_voucher_model.dart';

class FinanceVoucherRepositoryImpl implements FinanceVoucherRepository {
  final FinanceVoucherRemoteDs _remote;
  FinanceVoucherRepositoryImpl(this._remote);

  @override
  Future<FinanceVoucherHeader?> getHeader({
    required String clientId,
    required String companyId,
    required String transNo,
  }) => _remote.getHeader(
        clientId: clientId,
        companyId: companyId,
        transNo: transNo,
      );

  @override
  Future<List<FinanceVoucherLine>> getLines({
    required String clientId,
    required String companyId,
    required String transNo,
  }) => _remote.getLines(
        clientId: clientId,
        companyId: companyId,
        transNo: transNo,
      );

  @override
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required String userId,
  }) => _remote.save(header: header, lines: lines, userId: userId);

  @override
  Future<void> post({
    required String clientId,
    required String companyId,
    required String locationId,
    required String transNo,
    required String transDate,
    required String postedBy,
  }) => _remote.post(
        clientId:   clientId,
        companyId:  companyId,
        locationId: locationId,
        transNo:    transNo,
        transDate:  transDate,
        postedBy:   postedBy,
      );

  @override
  Future<List<Map<String, dynamic>>> getPendingBills({
    required String companyId,
    required String locationId,
    required String accountId,
  }) => _remote.getPendingBills(
        companyId:  companyId,
        locationId: locationId,
        accountId:  accountId,
      );

  @override
  Future<double?> fetchExchangeRate({
    required String companyId,
    required String locationId,
    required String fromCurrency,
    required String toCurrency,
    required String rateDate,
  }) => _remote.getExchangeRate(
        companyId:    companyId,
        locationId:   locationId,
        fromCurrency: fromCurrency,
        toCurrency:   toCurrency,
        rateDate:     rateDate,
      );
}
