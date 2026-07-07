import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/datasources/material_requisition_remote_ds.dart';
import '../../data/repositories/material_requisition_repository_impl.dart';
import '../../domain/repositories/material_requisition_repository.dart';

final _materialRequisitionRemoteDsProvider = Provider<MaterialRequisitionRemoteDs>(
  (_) => MaterialRequisitionRemoteDs(),
);

final materialRequisitionRepositoryProvider = Provider<MaterialRequisitionRepository>(
  (ref) => MaterialRequisitionRepositoryImpl(ref.watch(_materialRequisitionRemoteDsProvider)),
);
