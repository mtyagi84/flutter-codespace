import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/providers/session_provider.dart';
import '../../data/datasources/products_local_ds.dart';
import '../../data/datasources/products_remote_ds.dart';
import '../../data/repositories/products_repository_impl.dart';
import '../../domain/repositories/products_repository.dart';

final productsRepositoryProvider = Provider.autoDispose<ProductsRepository>(
  (ref) {
    final session = ref.watch(sessionProvider);
    final local   = kIsWeb
        ? null
        : ProductsLocalDs(ref.watch(appDatabaseProvider));
    return ProductsRepositoryImpl(
      remote:      ProductsRemoteDs(),
      local:       local,
      offlineMode: session?.offlineMode ?? false,
    );
  },
);
