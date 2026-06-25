import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/providers/session_provider.dart';
import '../../data/datasources/common_masters_local_ds.dart';
import '../../data/datasources/common_masters_remote_ds.dart';
import '../../data/repositories/common_masters_repository_impl.dart';
import '../../domain/repositories/common_masters_repository.dart';

final commonMastersRepositoryProvider = Provider<CommonMastersRepository>((ref) {
  final session = ref.watch(sessionProvider);
  final local   = kIsWeb
      ? null
      : CommonMastersLocalDs(ref.watch(appDatabaseProvider));
  return CommonMastersRepositoryImpl(
    remote:      CommonMastersRemoteDs(),
    local:       local,
    offlineMode: session?.offlineMode ?? false,
  );
});
