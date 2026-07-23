import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/providers/session_provider.dart';
import '../../data/datasources/expense_voucher_remote_ds.dart';
import '../../data/datasources/expense_voucher_local_ds.dart';
import '../../data/repositories/expense_voucher_repository_impl.dart';
import '../../domain/repositories/expense_voucher_repository.dart';

final _expenseVoucherRemoteDsProvider = Provider<ExpenseVoucherRemoteDs>(
  (_) => ExpenseVoucherRemoteDs(),
);

// Drift is not available on Flutter Web (requires web-worker setup).
// Web sessions are always online so local caching is not needed there.
final _expenseVoucherLocalDsProvider = Provider<ExpenseVoucherLocalDs?>(
  (ref) => kIsWeb ? null : ExpenseVoucherLocalDs(ref.watch(appDatabaseProvider)),
);

final expenseVoucherRepositoryProvider = Provider<ExpenseVoucherRepository>((ref) {
  final session = ref.watch(sessionProvider);
  final isOffline = session?.offlineMode ?? false;
  return ExpenseVoucherRepositoryImpl(
    ref.watch(_expenseVoucherRemoteDsProvider),
    ref.watch(_expenseVoucherLocalDsProvider),
    isOffline,
  );
});
