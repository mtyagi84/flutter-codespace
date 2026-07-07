import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/datasources/stock_receipt_remote_ds.dart';
import '../../data/repositories/stock_receipt_repository_impl.dart';
import '../../domain/repositories/stock_receipt_repository.dart';

final _stockReceiptRemoteDsProvider = Provider<StockReceiptRemoteDs>(
  (_) => StockReceiptRemoteDs(),
);

final stockReceiptRepositoryProvider = Provider<StockReceiptRepository>(
  (ref) => StockReceiptRepositoryImpl(ref.watch(_stockReceiptRemoteDsProvider)),
);
