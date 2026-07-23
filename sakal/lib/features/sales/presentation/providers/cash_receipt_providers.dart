import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/providers/session_provider.dart';
import '../../data/datasources/cash_receipt_remote_ds.dart';
import '../../data/datasources/cash_receipt_local_ds.dart';
import '../../data/repositories/cash_receipt_repository_impl.dart';
import '../../domain/repositories/cash_receipt_repository.dart';

final _cashReceiptRemoteDsProvider = Provider<CashReceiptRemoteDs>(
  (_) => CashReceiptRemoteDs(),
);

// Drift is not available on Flutter Web (requires web-worker setup).
// Web sessions are always online so local caching is not needed there.
final _cashReceiptLocalDsProvider = Provider<CashReceiptLocalDs?>(
  (ref) => kIsWeb ? null : CashReceiptLocalDs(ref.watch(appDatabaseProvider)),
);

final cashReceiptRepositoryProvider = Provider<CashReceiptRepository>((ref) {
  final session = ref.watch(sessionProvider);
  final isOffline = session?.offlineMode ?? false;
  return CashReceiptRepositoryImpl(
    ref.watch(_cashReceiptRemoteDsProvider),
    ref.watch(_cashReceiptLocalDsProvider),
    isOffline,
  );
});
