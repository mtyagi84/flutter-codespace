import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/providers/session_provider.dart';
import '../../data/datasources/price_master_remote_ds.dart';
import '../../data/datasources/price_master_local_ds.dart';
import '../../data/repositories/price_master_repository_impl.dart';
import '../../domain/repositories/price_master_repository.dart';

final _priceMasterRemoteDsProvider = Provider<PriceMasterRemoteDs>(
  (_) => PriceMasterRemoteDs(),
);

// Drift is not available on Flutter Web (requires web-worker setup).
// Web sessions are always online so local caching is not needed there.
final _priceMasterLocalDsProvider = Provider<PriceMasterLocalDs?>(
  (ref) => kIsWeb ? null : PriceMasterLocalDs(ref.watch(appDatabaseProvider)),
);

final priceMasterRepositoryProvider = Provider<PriceMasterRepository>((ref) {
  final session   = ref.watch(sessionProvider);
  final isOffline = session?.offlineMode ?? false;
  return PriceMasterRepositoryImpl(
    ref.watch(_priceMasterRemoteDsProvider),
    ref.watch(_priceMasterLocalDsProvider),
    isOffline,
  );
});
