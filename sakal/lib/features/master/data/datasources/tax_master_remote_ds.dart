import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';
import '../models/tax_group_member_model.dart';
import '../models/tax_group_model.dart';
import '../models/tax_model.dart';
import '../models/tax_rate_model.dart';
import '../models/tax_type_model.dart';

class TaxMasterRemoteDs {
  final Dio _dio = DioClient.instance;

  // ── Tax Types (global, no tenant filter) ───────────────────────────────────

  Future<List<TaxTypeModel>> getTaxTypes() async {
    final res = await _dio.get('/rim_tax_types', queryParameters: {
      'is_active': 'eq.true',
      'order':     'sort_order.asc',
    });
    return (res.data as List)
        .map((e) => TaxTypeModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ── Taxes ──────────────────────────────────────────────────────────────────

  Future<List<TaxModel>> getTaxes({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_taxes', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'order':      'sort_order.asc,tax_code.asc',
    });
    return (res.data as List)
        .map((e) => TaxModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveTax(Map<String, dynamic> payload) async {
    final id = payload['id'] as String?;
    if (id == null) {
      await _dio.post('/rim_taxes', data: payload);
    } else {
      await _dio.patch('/rim_taxes',
          queryParameters: {'id': 'eq.$id'}, data: payload);
    }
  }

  Future<void> softDeleteTax({
    required String id,
    required String userId,
  }) async {
    await _dio.patch('/rim_taxes',
        queryParameters: {'id': 'eq.$id'},
        data: {
          'is_deleted': true,
          'updated_by': userId,
          'updated_at': DateTime.now().toIso8601String(),
        });
  }

  // ── Compound Sources ────────────────────────────────────────────────────────

  Future<List<String>> getCompoundSourceIds(String compoundTaxId) async {
    final res = await _dio.get('/rim_tax_compound_sources', queryParameters: {
      'compound_tax_id': 'eq.$compoundTaxId',
      'select':          'source_tax_id',
    });
    return (res.data as List)
        .map((e) => e['source_tax_id'] as String)
        .toList();
  }

  Future<void> replaceCompoundSources({
    required String compoundTaxId,
    required String clientId,
    required String companyId,
    required List<String> sourceTaxIds,
    required String userId,
  }) async {
    await _dio.delete('/rim_tax_compound_sources',
        queryParameters: {'compound_tax_id': 'eq.$compoundTaxId'});
    for (final sourceId in sourceTaxIds) {
      await _dio.post('/rim_tax_compound_sources', data: {
        'client_id':       clientId,
        'company_id':      companyId,
        'compound_tax_id': compoundTaxId,
        'source_tax_id':   sourceId,
      });
    }
  }

  // ── Tax Rates ───────────────────────────────────────────────────────────────

  /// Load ALL rates for the company in one call — group by tax_id client-side.
  Future<List<TaxRateModel>> getAllRates({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_tax_rates', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'order':      'tax_id.asc,rate_label.asc,effective_from.desc',
    });
    return (res.data as List)
        .map((e) => TaxRateModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveRate(Map<String, dynamic> payload) async {
    final id = payload['id'] as String?;
    if (id == null) {
      await _dio.post('/rim_tax_rates', data: payload);
    } else {
      await _dio.patch('/rim_tax_rates',
          queryParameters: {'id': 'eq.$id'}, data: payload);
    }
  }

  Future<void> deactivateRate({
    required String id,
    required String userId,
    required String effectiveTo,
  }) async {
    await _dio.patch('/rim_tax_rates',
        queryParameters: {'id': 'eq.$id'},
        data: {
          'is_active':    false,
          'effective_to': effectiveTo,
          'updated_by':   userId,
          'updated_at':   DateTime.now().toIso8601String(),
        });
  }

  // ── Tax Groups ──────────────────────────────────────────────────────────────

  Future<List<TaxGroupModel>> getTaxGroups({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_tax_groups', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'order':      'sort_order.asc,group_code.asc',
    });
    return (res.data as List)
        .map((e) => TaxGroupModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveTaxGroup(Map<String, dynamic> payload) async {
    final id = payload['id'] as String?;
    if (id == null) {
      await _dio.post('/rim_tax_groups', data: payload);
    } else {
      await _dio.patch('/rim_tax_groups',
          queryParameters: {'id': 'eq.$id'}, data: payload);
    }
  }

  Future<void> softDeleteTaxGroup({
    required String id,
    required String userId,
  }) async {
    await _dio.patch('/rim_tax_groups',
        queryParameters: {'id': 'eq.$id'},
        data: {
          'is_deleted': true,
          'updated_by': userId,
          'updated_at': DateTime.now().toIso8601String(),
        });
  }

  // ── Group Members ───────────────────────────────────────────────────────────

  Future<List<TaxGroupMemberModel>> getMembersForGroup(String groupId) async {
    final res = await _dio.get('/rim_tax_group_members', queryParameters: {
      'tax_group_id': 'eq.$groupId',
      'order':        'sequence_no.asc',
    });
    return (res.data as List)
        .map((e) => TaxGroupMemberModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Atomic replace via PG function — avoids partial-update race on REST.
  Future<void> replaceGroupMembers({
    required String groupId,
    required String clientId,
    required String companyId,
    required List<TaxGroupMemberModel> members,
    required String userId,
  }) async {
    await _dio.post('/rpc/fn_replace_group_members', data: {
      'p_group_id':   groupId,
      'p_client_id':  clientId,
      'p_company_id': companyId,
      'p_members':    members.map((m) => m.toRpcJson()).toList(),
      'p_user_id':    userId,
    });
  }

  // ── Usage check ─────────────────────────────────────────────────────────────

  Future<int> countGroupsUsingTax(String taxId) async {
    final res = await _dio.get('/rim_tax_group_members', queryParameters: {
      'tax_id': 'eq.$taxId',
      'select': 'id',
    });
    return (res.data as List).length;
  }

  /// Lightweight fetch for GL account pickers — posting accounts only.
  Future<List<Map<String, String>>> getPostingAccounts({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_accounts', queryParameters: {
      'client_id':       'eq.$clientId',
      'company_id':      'eq.$companyId',
      'posting_allowed': 'eq.true',
      'is_deleted':      'eq.false',
      'select':          'id,account_code,account_name',
      'order':           'account_code.asc',
      'limit':           '500',
    });
    return (res.data as List)
        .map((e) => {
          'id':   e['id']           as String,
          'code': e['account_code'] as String,
          'name': e['account_name'] as String,
        })
        .toList();
  }
}
