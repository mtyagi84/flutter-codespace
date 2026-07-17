import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/database/datasources/generic_lookup_local_ds.dart';
import '../../../../core/database/datasources/tax_group_members_local_ds.dart';
import '../../../../core/database/datasources/tax_rates_local_ds.dart';
import '../../../../core/providers/session_provider.dart';
import '../../data/datasources/grn_remote_ds.dart';
import '../../data/datasources/grn_local_ds.dart';
import '../../data/repositories/grn_repository_impl.dart';
import '../../domain/repositories/grn_repository.dart';

final _grnRemoteDsProvider = Provider<GrnRemoteDs>(
  (_) => GrnRemoteDs(),
);

// Drift is not available on Flutter Web (requires web-worker setup).
// Web sessions are always online so local caching is not needed there.
final _grnLocalDsProvider = Provider<GrnLocalDs?>(
  (ref) => kIsWeb ? null : GrnLocalDs(ref.watch(appDatabaseProvider)),
);

final _grnLookupLocalDsProvider = Provider<GenericLookupLocalDs?>(
  (ref) => kIsWeb ? null : GenericLookupLocalDs(ref.watch(appDatabaseProvider)),
);

final _grnTaxGroupMembersLocalDsProvider = Provider<TaxGroupMembersLocalDs?>(
  (ref) => kIsWeb ? null : TaxGroupMembersLocalDs(ref.watch(appDatabaseProvider)),
);

final _grnTaxRatesLocalDsProvider = Provider<TaxRatesLocalDs?>(
  (ref) => kIsWeb ? null : TaxRatesLocalDs(ref.watch(appDatabaseProvider)),
);

final grnRepositoryProvider = Provider<GrnRepository>((ref) {
  final session   = ref.watch(sessionProvider);
  final isOffline = session?.offlineMode ?? false;
  return GrnRepositoryImpl(
    ref.watch(_grnRemoteDsProvider),
    ref.watch(_grnLocalDsProvider),
    ref.watch(_grnLookupLocalDsProvider),
    isOffline,
    session?.clientId ?? '',
    session?.companyId ?? '',
    taxGroupMembersLocal: ref.watch(_grnTaxGroupMembersLocalDsProvider),
    taxRatesLocal: ref.watch(_grnTaxRatesLocalDsProvider),
  );
});
