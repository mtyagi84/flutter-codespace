import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/providers/session_provider.dart';
import '../../data/datasources/purchase_return_remote_ds.dart';
import '../../data/datasources/purchase_return_local_ds.dart';
import '../../data/repositories/purchase_return_repository_impl.dart';
import '../../domain/repositories/purchase_return_repository.dart';

final _purchaseReturnRemoteDsProvider = Provider<PurchaseReturnRemoteDs>(
  (_) => PurchaseReturnRemoteDs(),
);

// Drift is not available on Flutter Web (requires web-worker setup).
// Web sessions are always online so local caching is not needed there.
final _purchaseReturnLocalDsProvider = Provider<PurchaseReturnLocalDs?>(
  (ref) => kIsWeb ? null : PurchaseReturnLocalDs(ref.watch(appDatabaseProvider)),
);

final purchaseReturnRepositoryProvider = Provider<PurchaseReturnRepository>((ref) {
  final session   = ref.watch(sessionProvider);
  final isOffline = session?.offlineMode ?? false;
  return PurchaseReturnRepositoryImpl(
    ref.watch(_purchaseReturnRemoteDsProvider),
    ref.watch(_purchaseReturnLocalDsProvider),
    isOffline,
  );
});
