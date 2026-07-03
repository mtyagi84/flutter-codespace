import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/database/datasources/generic_lookup_local_ds.dart';
import '../../../../core/providers/session_provider.dart';
import '../../data/datasources/purchase_order_remote_ds.dart';
import '../../data/datasources/purchase_order_local_ds.dart';
import '../../data/repositories/purchase_order_repository_impl.dart';
import '../../domain/repositories/purchase_order_repository.dart';

final _remoteDsProvider = Provider<PurchaseOrderRemoteDs>(
  (_) => PurchaseOrderRemoteDs(),
);

// Drift is not available on Flutter Web (requires web-worker setup).
// Web sessions are always online so local caching is not needed there.
final _localDsProvider = Provider<PurchaseOrderLocalDs?>(
  (ref) => kIsWeb ? null : PurchaseOrderLocalDs(ref.watch(appDatabaseProvider)),
);

final _lookupLocalDsProvider = Provider<GenericLookupLocalDs?>(
  (ref) => kIsWeb ? null : GenericLookupLocalDs(ref.watch(appDatabaseProvider)),
);

final purchaseOrderRepositoryProvider = Provider<PurchaseOrderRepository>((ref) {
  final session   = ref.watch(sessionProvider);
  final isOffline = session?.offlineMode ?? false;
  return PurchaseOrderRepositoryImpl(
    ref.watch(_remoteDsProvider),
    ref.watch(_localDsProvider),
    ref.watch(_lookupLocalDsProvider),
    isOffline,
    session?.clientId ?? '',
    session?.companyId ?? '',
  );
});
