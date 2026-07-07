import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/datasources/department_consumption_area_remote_ds.dart';
import '../../data/repositories/department_consumption_area_repository_impl.dart';
import '../../domain/repositories/department_consumption_area_repository.dart';

final _departmentConsumptionAreaRemoteDsProvider = Provider<DepartmentConsumptionAreaRemoteDs>(
  (_) => DepartmentConsumptionAreaRemoteDs(),
);

final departmentConsumptionAreaRepositoryProvider = Provider<DepartmentConsumptionAreaRepository>(
  (ref) => DepartmentConsumptionAreaRepositoryImpl(ref.watch(_departmentConsumptionAreaRemoteDsProvider)),
);
