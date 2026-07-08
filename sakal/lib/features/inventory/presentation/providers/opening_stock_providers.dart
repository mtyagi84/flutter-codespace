import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/providers/session_provider.dart';
import '../../data/datasources/opening_stock_remote_ds.dart';
import '../../data/datasources/opening_stock_local_ds.dart';
import '../../data/repositories/opening_stock_repository_impl.dart';
import '../../domain/repositories/opening_stock_repository.dart';

final _openingStockRemoteDsProvider = Provider<OpeningStockRemoteDs>(
  (_) => OpeningStockRemoteDs(),
);

// Drift is not available on Flutter Web (requires web-worker setup).
// Web sessions are always online so local caching is not needed there.
final _openingStockLocalDsProvider = Provider<OpeningStockLocalDs?>(
  (ref) => kIsWeb ? null : OpeningStockLocalDs(ref.watch(appDatabaseProvider)),
);

final openingStockRepositoryProvider = Provider<OpeningStockRepository>((ref) {
  final session   = ref.watch(sessionProvider);
  final isOffline = session?.offlineMode ?? false;
  return OpeningStockRepositoryImpl(
    ref.watch(_openingStockRemoteDsProvider),
    ref.watch(_openingStockLocalDsProvider),
    isOffline,
  );
});
