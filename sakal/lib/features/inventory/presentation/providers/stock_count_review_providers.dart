import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/datasources/stock_count_review_remote_ds.dart';
import '../../data/repositories/stock_count_review_repository_impl.dart';
import '../../domain/repositories/stock_count_review_repository.dart';

final _stockCountReviewRemoteDsProvider = Provider<StockCountReviewRemoteDs>(
  (_) => StockCountReviewRemoteDs(),
);

final stockCountReviewRepositoryProvider = Provider<StockCountReviewRepository>(
  (ref) => StockCountReviewRepositoryImpl(ref.watch(_stockCountReviewRemoteDsProvider)),
);
