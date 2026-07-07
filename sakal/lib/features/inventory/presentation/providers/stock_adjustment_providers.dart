import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/providers/session_provider.dart';
import '../../data/datasources/stock_adjustment_remote_ds.dart';
import '../../data/datasources/stock_adjustment_local_ds.dart';
import '../../data/repositories/stock_adjustment_repository_impl.dart';
import '../../domain/repositories/stock_adjustment_repository.dart';

final _stockAdjustmentRemoteDsProvider = Provider<StockAdjustmentRemoteDs>(
  (_) => StockAdjustmentRemoteDs(),
);

// Drift is not available on Flutter Web (requires web-worker setup).
// Web sessions are always online so local caching is not needed there.
final _stockAdjustmentLocalDsProvider = Provider<StockAdjustmentLocalDs?>(
  (ref) => kIsWeb ? null : StockAdjustmentLocalDs(ref.watch(appDatabaseProvider)),
);

final stockAdjustmentRepositoryProvider = Provider<StockAdjustmentRepository>((ref) {
  final session   = ref.watch(sessionProvider);
  final isOffline = session?.offlineMode ?? false;
  return StockAdjustmentRepositoryImpl(
    ref.watch(_stockAdjustmentRemoteDsProvider),
    ref.watch(_stockAdjustmentLocalDsProvider),
    isOffline,
  );
});
