import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/providers/session_provider.dart';
import '../../data/datasources/finance_voucher_remote_ds.dart';
import '../../data/datasources/finance_voucher_local_ds.dart';
import '../../data/repositories/finance_voucher_repository_impl.dart';
import '../../domain/repositories/finance_voucher_repository.dart';

final _remoteDsProvider = Provider<FinanceVoucherRemoteDs>(
  (_) => FinanceVoucherRemoteDs(),
);

final _localDsProvider = Provider<FinanceVoucherLocalDs>(
  (ref) => FinanceVoucherLocalDs(ref.watch(appDatabaseProvider)),
);

final financeVoucherRepositoryProvider = Provider<FinanceVoucherRepository>((ref) {
  final isOffline = ref.watch(sessionProvider)?.offlineMode ?? false;
  return FinanceVoucherRepositoryImpl(
    ref.watch(_remoteDsProvider),
    ref.watch(_localDsProvider),
    isOffline,
  );
});
