import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/datasources/purchase_return_remote_ds.dart';
import '../../data/repositories/purchase_return_repository_impl.dart';
import '../../domain/repositories/purchase_return_repository.dart';

final _purchaseReturnRemoteDsProvider = Provider<PurchaseReturnRemoteDs>(
  (_) => PurchaseReturnRemoteDs(),
);

final purchaseReturnRepositoryProvider = Provider<PurchaseReturnRepository>(
  (ref) => PurchaseReturnRepositoryImpl(ref.watch(_purchaseReturnRemoteDsProvider)),
);
