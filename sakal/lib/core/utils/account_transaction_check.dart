import '../network/dio_client.dart';

/// Whether [accountId] has ever been posted to the GL ledger
/// (`rid_finance_lines`) -- every module in this app posts through the
/// shared posting engines (fn_post_voucher / fn_post_finance_voucher),
/// so a single indexed existence check here covers every transaction
/// type uniformly (sales, purchase, payments, receipts, ...), not just
/// one module's own tables.
///
/// Used to gate a currency CHANGE on an existing party account -- never
/// to gate the account's own is_active toggle, which is always freely
/// reversible regardless of transaction history.
Future<bool> accountHasTransactions(String accountId) async {
  final res = await DioClient.instance.get('/rid_finance_lines', queryParameters: {
    'account_id': 'eq.$accountId',
    'is_deleted': 'eq.false',
    'select':     'id',
    'limit':      '1',
  });
  return (res.data as List).isNotEmpty;
}
