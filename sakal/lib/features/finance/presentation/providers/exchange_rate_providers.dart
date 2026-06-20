import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/providers/session_provider.dart';
import '../../data/datasources/exchange_rate_local_ds.dart';
import '../../data/datasources/exchange_rate_remote_ds.dart';
import '../../data/repositories/exchange_rate_repository_impl.dart';
import '../../domain/repositories/exchange_rate_repository.dart';

final exchangeRateRepositoryProvider = Provider<ExchangeRateRepository>((ref) {
  final session = ref.watch(sessionProvider);
  return ExchangeRateRepositoryImpl(
    remote:      ExchangeRateRemoteDs(),
    local:       ExchangeRateLocalDs(ref.watch(appDatabaseProvider)),
    offlineMode: session?.offlineMode ?? false,
  );
});
