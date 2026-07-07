import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/providers/session_provider.dart';
import '../../data/datasources/stock_transfer_request_remote_ds.dart';
import '../../data/datasources/stock_transfer_request_local_ds.dart';
import '../../data/repositories/stock_transfer_request_repository_impl.dart';
import '../../domain/repositories/stock_transfer_request_repository.dart';

final _stockTransferRequestRemoteDsProvider = Provider<StockTransferRequestRemoteDs>(
  (_) => StockTransferRequestRemoteDs(),
);

// Drift is not available on Flutter Web (requires web-worker setup).
// Web sessions are always online so local caching is not needed there.
final _stockTransferRequestLocalDsProvider = Provider<StockTransferRequestLocalDs?>(
  (ref) => kIsWeb ? null : StockTransferRequestLocalDs(ref.watch(appDatabaseProvider)),
);

final stockTransferRequestRepositoryProvider = Provider<StockTransferRequestRepository>((ref) {
  final session   = ref.watch(sessionProvider);
  final isOffline = session?.offlineMode ?? false;
  return StockTransferRequestRepositoryImpl(
    ref.watch(_stockTransferRequestRemoteDsProvider),
    ref.watch(_stockTransferRequestLocalDsProvider),
    isOffline,
  );
});
