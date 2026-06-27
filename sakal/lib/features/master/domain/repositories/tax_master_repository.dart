import '../../data/models/tax_group_member_model.dart';
import '../../data/models/tax_group_model.dart';
import '../../data/models/tax_model.dart';
import '../../data/models/tax_rate_model.dart';
import '../../data/models/tax_type_model.dart';

abstract class TaxMasterRepository {
  Future<List<TaxTypeModel>> getTaxTypes();

  Future<List<TaxModel>>     getTaxes({required String clientId, required String companyId});
  Future<void> saveTax(Map<String, dynamic> payload);
  Future<void> softDeleteTax({required String id, required String userId});

  Future<List<String>> getCompoundSourceIds(String compoundTaxId);
  Future<void> replaceCompoundSources({
    required String compoundTaxId,
    required String clientId,
    required String companyId,
    required List<String> sourceTaxIds,
    required String userId,
  });

  Future<List<TaxRateModel>> getAllRates({required String clientId, required String companyId});
  Future<void> saveRate(Map<String, dynamic> payload);
  Future<void> deactivateRate({required String id, required String userId, required String effectiveTo});

  Future<List<TaxGroupModel>>       getTaxGroups({required String clientId, required String companyId});
  Future<void> saveTaxGroup(Map<String, dynamic> payload);
  Future<void> softDeleteTaxGroup({required String id, required String userId});

  Future<List<TaxGroupMemberModel>> getMembersForGroup(String groupId);
  Future<void> replaceGroupMembers({
    required String groupId,
    required String clientId,
    required String companyId,
    required List<TaxGroupMemberModel> members,
    required String userId,
  });

  Future<int> countGroupsUsingTax(String taxId);
}
