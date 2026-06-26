import '../../data/models/common_master_model.dart';
import '../../data/models/common_master_type_model.dart';

abstract class CommonMastersRepository {
  Future<List<CommonMasterTypeModel>> getTypes();

  Future<List<CommonMasterModel>> getMasters({
    required String clientId,
    required String companyId,
    required String typeId,
    String? search,
    int limit,
    int offset,
  });

  Future<void> saveMaster(Map<String, dynamic> payload);

  Future<void> softDelete({required String id, required String userId});
}
