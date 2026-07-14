import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/providers/session_provider.dart';
import '../../data/datasources/sales_order_remote_ds.dart';
import '../../data/datasources/sales_order_local_ds.dart';
import '../../data/repositories/sales_order_repository_impl.dart';
import '../../domain/repositories/sales_order_repository.dart';

final _salesOrderRemoteDsProvider = Provider<SalesOrderRemoteDs>(
  (_) => SalesOrderRemoteDs(),
);

// Drift is not available on Flutter Web (requires web-worker setup).
// Web sessions are always online so local caching is not needed there.
final _salesOrderLocalDsProvider = Provider<SalesOrderLocalDs?>(
  (ref) => kIsWeb ? null : SalesOrderLocalDs(ref.watch(appDatabaseProvider)),
);

final salesOrderRepositoryProvider = Provider<SalesOrderRepository>((ref) {
  final session   = ref.watch(sessionProvider);
  final isOffline = session?.offlineMode ?? false;
  return SalesOrderRepositoryImpl(
    ref.watch(_salesOrderRemoteDsProvider),
    ref.watch(_salesOrderLocalDsProvider),
    isOffline,
  );
});
