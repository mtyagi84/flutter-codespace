import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/datasources/stock_transfer_request_remote_ds.dart';
import '../../data/repositories/stock_transfer_request_repository_impl.dart';
import '../../domain/repositories/stock_transfer_request_repository.dart';

final _stockTransferRequestRemoteDsProvider = Provider<StockTransferRequestRemoteDs>(
  (_) => StockTransferRequestRemoteDs(),
);

final stockTransferRequestRepositoryProvider = Provider<StockTransferRequestRepository>(
  (ref) => StockTransferRequestRepositoryImpl(ref.watch(_stockTransferRequestRemoteDsProvider)),
);
