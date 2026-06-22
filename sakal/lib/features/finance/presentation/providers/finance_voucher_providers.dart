import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/datasources/finance_voucher_remote_ds.dart';
import '../../data/repositories/finance_voucher_repository_impl.dart';
import '../../domain/repositories/finance_voucher_repository.dart';

final _remoteDsProvider = Provider<FinanceVoucherRemoteDs>(
  (_) => FinanceVoucherRemoteDs(),
);

final financeVoucherRepositoryProvider = Provider<FinanceVoucherRepository>(
  (ref) => FinanceVoucherRepositoryImpl(ref.watch(_remoteDsProvider)),
);
