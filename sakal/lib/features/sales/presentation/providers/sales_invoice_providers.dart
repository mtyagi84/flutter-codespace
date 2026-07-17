import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/providers/session_provider.dart';
import '../../data/datasources/sales_invoice_remote_ds.dart';
import '../../data/datasources/sales_invoice_local_ds.dart';
import '../../data/repositories/sales_invoice_repository_impl.dart';
import '../../domain/repositories/sales_invoice_repository.dart';

final _salesInvoiceRemoteDsProvider = Provider<SalesInvoiceRemoteDs>(
  (_) => SalesInvoiceRemoteDs(),
);

// Drift is not available on Flutter Web (requires web-worker setup).
// Web sessions are always online so local caching is not needed there.
final _salesInvoiceLocalDsProvider = Provider<SalesInvoiceLocalDs?>(
  (ref) => kIsWeb ? null : SalesInvoiceLocalDs(ref.watch(appDatabaseProvider)),
);

final salesInvoiceRepositoryProvider = Provider<SalesInvoiceRepository>((ref) {
  final session   = ref.watch(sessionProvider);
  final isOffline = session?.offlineMode ?? false;
  return SalesInvoiceRepositoryImpl(
    ref.watch(_salesInvoiceRemoteDsProvider),
    ref.watch(_salesInvoiceLocalDsProvider),
    isOffline,
  );
});
