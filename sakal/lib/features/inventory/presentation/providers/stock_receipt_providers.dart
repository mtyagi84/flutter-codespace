import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/providers/session_provider.dart';
import '../../data/datasources/stock_receipt_remote_ds.dart';
import '../../data/datasources/stock_receipt_local_ds.dart';
import '../../data/repositories/stock_receipt_repository_impl.dart';
import '../../domain/repositories/stock_receipt_repository.dart';

final _stockReceiptRemoteDsProvider = Provider<StockReceiptRemoteDs>(
  (_) => StockReceiptRemoteDs(),
);

// Drift is not available on Flutter Web (requires web-worker setup).
// Web sessions are always online so local caching is not needed there.
final _stockReceiptLocalDsProvider = Provider<StockReceiptLocalDs?>(
  (ref) => kIsWeb ? null : StockReceiptLocalDs(ref.watch(appDatabaseProvider)),
);

final stockReceiptRepositoryProvider = Provider<StockReceiptRepository>((ref) {
  final session   = ref.watch(sessionProvider);
  final isOffline = session?.offlineMode ?? false;
  return StockReceiptRepositoryImpl(
    ref.watch(_stockReceiptRemoteDsProvider),
    ref.watch(_stockReceiptLocalDsProvider),
    isOffline,
  );
});
