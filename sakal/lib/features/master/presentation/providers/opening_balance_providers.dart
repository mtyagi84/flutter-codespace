import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/datasources/opening_balance_remote_ds.dart';
import '../../data/repositories/opening_balance_repository_impl.dart';
import '../../domain/repositories/opening_balance_repository.dart';

final openingBalanceRepositoryProvider = Provider<OpeningBalanceRepository>(
  (ref) => OpeningBalanceRepositoryImpl(OpeningBalanceRemoteDs()),
);
