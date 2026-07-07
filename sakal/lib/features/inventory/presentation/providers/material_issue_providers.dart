import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/providers/session_provider.dart';
import '../../data/datasources/material_issue_remote_ds.dart';
import '../../data/datasources/material_issue_local_ds.dart';
import '../../data/repositories/material_issue_repository_impl.dart';
import '../../domain/repositories/material_issue_repository.dart';

final _materialIssueRemoteDsProvider = Provider<MaterialIssueRemoteDs>(
  (_) => MaterialIssueRemoteDs(),
);

// Drift is not available on Flutter Web (requires web-worker setup).
// Web sessions are always online so local caching is not needed there.
final _materialIssueLocalDsProvider = Provider<MaterialIssueLocalDs?>(
  (ref) => kIsWeb ? null : MaterialIssueLocalDs(ref.watch(appDatabaseProvider)),
);

final materialIssueRepositoryProvider = Provider<MaterialIssueRepository>((ref) {
  final session   = ref.watch(sessionProvider);
  final isOffline = session?.offlineMode ?? false;
  return MaterialIssueRepositoryImpl(
    ref.watch(_materialIssueRemoteDsProvider),
    ref.watch(_materialIssueLocalDsProvider),
    isOffline,
  );
});
