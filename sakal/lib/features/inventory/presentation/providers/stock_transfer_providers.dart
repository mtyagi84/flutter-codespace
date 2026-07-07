import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/datasources/stock_transfer_remote_ds.dart';
import '../../data/repositories/stock_transfer_repository_impl.dart';
import '../../domain/repositories/stock_transfer_repository.dart';

final _stockTransferRemoteDsProvider = Provider<StockTransferRemoteDs>(
  (_) => StockTransferRemoteDs(),
);

final stockTransferRepositoryProvider = Provider<StockTransferRepository>(
  (ref) => StockTransferRepositoryImpl(ref.watch(_stockTransferRemoteDsProvider)),
);
