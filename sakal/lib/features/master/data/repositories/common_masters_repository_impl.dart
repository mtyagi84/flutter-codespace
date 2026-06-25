import '../../domain/repositories/common_masters_repository.dart';
import '../datasources/common_masters_local_ds.dart';
import '../datasources/common_masters_remote_ds.dart';
import '../models/common_master_model.dart';
import '../models/common_master_type_model.dart';

class CommonMastersRepositoryImpl implements CommonMastersRepository {
  final CommonMastersRemoteDs  _remote;
  final CommonMastersLocalDs?  _local;   // null on web (no SQLite WASM)
  final bool                   _offlineMode;

  CommonMastersRepositoryImpl({
    required CommonMastersRemoteDs  remote,
    required CommonMastersLocalDs?  local,
    required bool                   offlineMode,
  })  : _remote      = remote,
        _local       = local,
        _offlineMode = offlineMode;

  @override
  Future<List<CommonMasterTypeModel>> getTypes() async {
    if (_offlineMode) {
      return _local!.getTypes();
    }
    final types = await _remote.getTypes();
    try { await _local?.upsertTypes(types); } catch (_) {}
    return types;
  }

  @override
  Future<List<CommonMasterModel>> getMasters({
    required String clientId,
    required String companyId,
    required String typeId,
    String? search,
    int limit  = 50,
    int offset = 0,
  }) async {
    if (_offlineMode) {
      // Offline: no pagination/search — serve full cached list
      return _local!.getMasters(
        clientId:  clientId,
        companyId: companyId,
        typeId:    typeId,
      );
    }
    final masters = await _remote.getMasters(
      clientId:  clientId,
      companyId: companyId,
      typeId:    typeId,
      search:    search,
      limit:     limit,
      offset:    offset,
    );
    // Cache only first-page, no-search results for offline use
    if (offset == 0 && (search == null || search.isEmpty)) {
      try { await _local?.upsertMasters(masters); } catch (_) {}
    }
    return masters;
  }

  // Always remote — write buttons are hidden when offline
  @override
  Future<CommonMasterModel> saveMaster(Map<String, dynamic> payload) =>
      _remote.saveMaster(payload);

  // Always remote — write buttons are hidden when offline
  @override
  Future<void> softDelete({required String id, required String userId}) =>
      _remote.softDelete(id: id, userId: userId);
}
