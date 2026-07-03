import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/database/datasources/generic_lookup_local_ds.dart';
import '../../../../core/providers/session_provider.dart';
import '../../data/datasources/item_categories_remote_ds.dart';
import '../../data/repositories/item_categories_repository_impl.dart';
import '../../domain/repositories/item_categories_repository.dart';

final _remoteDsProvider = Provider<ItemCategoriesRemoteDs>(
  (_) => ItemCategoriesRemoteDs(),
);

// Drift is not available on Flutter Web (requires web-worker setup).
// Web sessions are always online so local caching is not needed there.
final _lookupLocalDsProvider = Provider<GenericLookupLocalDs?>(
  (ref) => kIsWeb ? null : GenericLookupLocalDs(ref.watch(appDatabaseProvider)),
);

final itemCategoriesRepositoryProvider = Provider<ItemCategoriesRepository>((ref) {
  final session   = ref.watch(sessionProvider);
  final isOffline = session?.offlineMode ?? false;
  return ItemCategoriesRepositoryImpl(
    ref.watch(_remoteDsProvider),
    ref.watch(_lookupLocalDsProvider),
    isOffline,
    session?.clientId ?? '',
    session?.companyId ?? '',
  );
});
