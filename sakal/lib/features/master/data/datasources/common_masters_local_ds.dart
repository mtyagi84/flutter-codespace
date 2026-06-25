import 'package:drift/drift.dart';
import '../../../../core/database/app_database.dart';
import '../models/common_master_model.dart';
import '../models/common_master_type_model.dart';

class CommonMastersLocalDs {
  final AppDatabase _db;
  CommonMastersLocalDs(this._db);

  // ── Types ──────────────────────────────────────────────────────────────────

  Future<List<CommonMasterTypeModel>> getTypes() async {
    final rows = await (_db.select(_db.commonMasterTypesCache)
          ..where((t) => t.isActive.equals(true))
          ..orderBy([(t) => OrderingTerm.asc(t.typeName)]))
        .get();
    return rows
        .map((e) => CommonMasterTypeModel(
              id:       e.id,
              typeKey:  e.typeKey,
              typeName: e.typeName,
              isActive: e.isActive,
            ))
        .toList();
  }

  Future<void> upsertTypes(List<CommonMasterTypeModel> types) async {
    await _db.batch((batch) {
      for (final t in types) {
        batch.insert(
          _db.commonMasterTypesCache,
          CommonMasterTypeCacheEntry(
            id:       t.id,
            typeKey:  t.typeKey,
            typeName: t.typeName,
            isActive: t.isActive,
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  // ── Masters ────────────────────────────────────────────────────────────────

  Future<List<CommonMasterModel>> getMasters({
    required String clientId,
    required String companyId,
    required String typeId,
  }) async {
    final rows = await (_db.select(_db.commonMastersCache)
          ..where((t) =>
              t.clientId.equals(clientId) &
              t.companyId.equals(companyId) &
              t.typeId.equals(typeId) &
              t.isDeleted.equals(false))
          ..orderBy([
            (t) => OrderingTerm.asc(t.sortOrder),
            (t) => OrderingTerm.asc(t.description),
          ]))
        .get();
    return rows.map(_toModel).toList();
  }

  Future<void> upsertMasters(List<CommonMasterModel> masters) async {
    await _db.batch((batch) {
      for (final m in masters) {
        batch.insert(
          _db.commonMastersCache,
          CommonMasterCacheEntry(
            id:          m.id,
            clientId:    m.clientId,
            companyId:   m.companyId,
            typeId:      m.typeId,
            description: m.description,
            shortName:   m.shortName,
            sortOrder:   m.sortOrder,
            isActive:    m.isActive,
            isDeleted:   m.isDeleted,
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  CommonMasterModel _toModel(CommonMasterCacheEntry e) => CommonMasterModel(
        id:          e.id,
        clientId:    e.clientId,
        companyId:   e.companyId,
        typeId:      e.typeId,
        description: e.description,
        shortName:   e.shortName,
        sortOrder:   e.sortOrder,
        isActive:    e.isActive,
        isDeleted:   e.isDeleted,
      );
}
