import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/providers/session_provider.dart';
import '../../data/datasources/stock_count_remote_ds.dart';
import '../../data/datasources/stock_count_local_ds.dart';
import '../../data/repositories/stock_count_repository_impl.dart';
import '../../domain/repositories/stock_count_repository.dart';

final _stockCountRemoteDsProvider = Provider<StockCountRemoteDs>(
  (_) => StockCountRemoteDs(),
);

// Drift is not available on Flutter Web (requires web-worker setup).
// Web sessions are always online so local caching is not needed there.
final _stockCountLocalDsProvider = Provider<StockCountLocalDs?>(
  (ref) => kIsWeb ? null : StockCountLocalDs(ref.watch(appDatabaseProvider)),
);

final stockCountRepositoryProvider = Provider<StockCountRepository>((ref) {
  final session   = ref.watch(sessionProvider);
  final isOffline = session?.offlineMode ?? false;
  return StockCountRepositoryImpl(
    ref.watch(_stockCountRemoteDsProvider),
    ref.watch(_stockCountLocalDsProvider),
    isOffline,
  );
});
