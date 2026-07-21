import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/providers/session_provider.dart';
import '../../data/datasources/sales_delivery_remote_ds.dart';
import '../../data/datasources/sales_delivery_local_ds.dart';
import '../../data/repositories/sales_delivery_repository_impl.dart';
import '../../domain/repositories/sales_delivery_repository.dart';

final _salesDeliveryRemoteDsProvider = Provider<SalesDeliveryRemoteDs>(
  (_) => SalesDeliveryRemoteDs(),
);

// Drift is not available on Flutter Web (requires web-worker setup).
// Web sessions are always online so local caching is not needed there.
final _salesDeliveryLocalDsProvider = Provider<SalesDeliveryLocalDs?>(
  (ref) => kIsWeb ? null : SalesDeliveryLocalDs(ref.watch(appDatabaseProvider)),
);

final salesDeliveryRepositoryProvider = Provider<SalesDeliveryRepository>((ref) {
  final session   = ref.watch(sessionProvider);
  final isOffline = session?.offlineMode ?? false;
  return SalesDeliveryRepositoryImpl(
    ref.watch(_salesDeliveryRemoteDsProvider),
    ref.watch(_salesDeliveryLocalDsProvider),
    isOffline,
  );
});
