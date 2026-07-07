import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/providers/session_provider.dart';
import '../../data/datasources/stock_transfer_remote_ds.dart';
import '../../data/datasources/stock_transfer_local_ds.dart';
import '../../data/repositories/stock_transfer_repository_impl.dart';
import '../../domain/repositories/stock_transfer_repository.dart';

final _stockTransferRemoteDsProvider = Provider<StockTransferRemoteDs>(
  (_) => StockTransferRemoteDs(),
);

// Drift is not available on Flutter Web (requires web-worker setup).
// Web sessions are always online so local caching is not needed there.
final _stockTransferLocalDsProvider = Provider<StockTransferLocalDs?>(
  (ref) => kIsWeb ? null : StockTransferLocalDs(ref.watch(appDatabaseProvider)),
);

final stockTransferRepositoryProvider = Provider<StockTransferRepository>((ref) {
  final session   = ref.watch(sessionProvider);
  final isOffline = session?.offlineMode ?? false;
  return StockTransferRepositoryImpl(
    ref.watch(_stockTransferRemoteDsProvider),
    ref.watch(_stockTransferLocalDsProvider),
    isOffline,
  );
});
