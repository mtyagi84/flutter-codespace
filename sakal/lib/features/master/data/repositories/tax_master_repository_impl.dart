import '../../domain/repositories/tax_master_repository.dart';
import '../datasources/tax_master_remote_ds.dart';
import '../models/tax_group_member_model.dart';
import '../models/tax_group_model.dart';
import '../models/tax_model.dart';
import '../models/tax_rate_model.dart';
import '../models/tax_type_model.dart';

class TaxMasterRepositoryImpl implements TaxMasterRepository {
  final TaxMasterRemoteDs _remote;
  TaxMasterRepositoryImpl(this._remote);

  @override Future<List<TaxTypeModel>> getTaxTypes() => _remote.getTaxTypes();

  @override Future<List<TaxModel>> getTaxes({required String clientId, required String companyId}) =>
      _remote.getTaxes(clientId: clientId, companyId: companyId);
  @override Future<void> saveTax(Map<String, dynamic> p) => _remote.saveTax(p);
  @override Future<void> softDeleteTax({required String id, required String userId}) =>
      _remote.softDeleteTax(id: id, userId: userId);

  @override Future<List<String>> getCompoundSourceIds(String compoundTaxId) =>
      _remote.getCompoundSourceIds(compoundTaxId);
  @override Future<void> replaceCompoundSources({
    required String compoundTaxId, required String clientId, required String companyId,
    required List<String> sourceTaxIds, required String userId,
  }) => _remote.replaceCompoundSources(
    compoundTaxId: compoundTaxId, clientId: clientId, companyId: companyId,
    sourceTaxIds: sourceTaxIds, userId: userId,
  );

  @override Future<List<TaxRateModel>> getAllRates({required String clientId, required String companyId}) =>
      _remote.getAllRates(clientId: clientId, companyId: companyId);
  @override Future<void> saveRate(Map<String, dynamic> p) => _remote.saveRate(p);
  @override Future<void> deactivateRate({required String id, required String userId, required String effectiveTo}) =>
      _remote.deactivateRate(id: id, userId: userId, effectiveTo: effectiveTo);

  @override Future<List<TaxGroupModel>> getTaxGroups({required String clientId, required String companyId}) =>
      _remote.getTaxGroups(clientId: clientId, companyId: companyId);
  @override Future<void> saveTaxGroup(Map<String, dynamic> p) => _remote.saveTaxGroup(p);
  @override Future<void> softDeleteTaxGroup({required String id, required String userId}) =>
      _remote.softDeleteTaxGroup(id: id, userId: userId);

  @override Future<List<TaxGroupMemberModel>> getMembersForGroup(String groupId) =>
      _remote.getMembersForGroup(groupId);
  @override Future<void> replaceGroupMembers({
    required String groupId, required String clientId, required String companyId,
    required List<TaxGroupMemberModel> members, required String userId,
  }) => _remote.replaceGroupMembers(
    groupId: groupId, clientId: clientId, companyId: companyId,
    members: members, userId: userId,
  );

  @override Future<int> countGroupsUsingTax(String taxId) =>
      _remote.countGroupsUsingTax(taxId);
}
