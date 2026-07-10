import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/providers/session_provider.dart';
import '../../data/datasources/sales_quotation_remote_ds.dart';
import '../../data/datasources/sales_quotation_local_ds.dart';
import '../../data/repositories/sales_quotation_repository_impl.dart';
import '../../domain/repositories/sales_quotation_repository.dart';

final _salesQuotationRemoteDsProvider = Provider<SalesQuotationRemoteDs>(
  (_) => SalesQuotationRemoteDs(),
);

// Drift is not available on Flutter Web (requires web-worker setup).
// Web sessions are always online so local caching is not needed there.
final _salesQuotationLocalDsProvider = Provider<SalesQuotationLocalDs?>(
  (ref) => kIsWeb ? null : SalesQuotationLocalDs(ref.watch(appDatabaseProvider)),
);

final salesQuotationRepositoryProvider = Provider<SalesQuotationRepository>((ref) {
  final session   = ref.watch(sessionProvider);
  final isOffline = session?.offlineMode ?? false;
  return SalesQuotationRepositoryImpl(
    ref.watch(_salesQuotationRemoteDsProvider),
    ref.watch(_salesQuotationLocalDsProvider),
    isOffline,
  );
});
