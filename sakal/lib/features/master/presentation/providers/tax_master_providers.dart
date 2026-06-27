import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/datasources/tax_master_remote_ds.dart';
import '../../data/repositories/tax_master_repository_impl.dart';
import '../../domain/repositories/tax_master_repository.dart';

final taxMasterRepositoryProvider = Provider<TaxMasterRepository>(
  (ref) => TaxMasterRepositoryImpl(TaxMasterRemoteDs()),
);
