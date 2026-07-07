import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/providers/session_provider.dart';
import '../../data/datasources/material_requisition_remote_ds.dart';
import '../../data/datasources/material_requisition_local_ds.dart';
import '../../data/repositories/material_requisition_repository_impl.dart';
import '../../domain/repositories/material_requisition_repository.dart';

final _materialRequisitionRemoteDsProvider = Provider<MaterialRequisitionRemoteDs>(
  (_) => MaterialRequisitionRemoteDs(),
);

// Drift is not available on Flutter Web (requires web-worker setup).
// Web sessions are always online so local caching is not needed there.
final _materialRequisitionLocalDsProvider = Provider<MaterialRequisitionLocalDs?>(
  (ref) => kIsWeb ? null : MaterialRequisitionLocalDs(ref.watch(appDatabaseProvider)),
);

final materialRequisitionRepositoryProvider = Provider<MaterialRequisitionRepository>((ref) {
  final session   = ref.watch(sessionProvider);
  final isOffline = session?.offlineMode ?? false;
  return MaterialRequisitionRepositoryImpl(
    ref.watch(_materialRequisitionRemoteDsProvider),
    ref.watch(_materialRequisitionLocalDsProvider),
    isOffline,
  );
});
