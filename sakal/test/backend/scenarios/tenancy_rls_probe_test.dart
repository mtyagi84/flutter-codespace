import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';

/// Permanent regression test for migration 188 — the three ROOT tenancy
/// tables (ric_clients, ric_companies, ric_locations, created in
/// 001_tenancy.sql) sat on the original "dev_allow_all" permissive RLS
/// policy from day one. A full grep of every migration for GRANT/REVOKE/
/// POLICY statements touching any of the three found nothing after 001 —
/// confirmed live 2026-09-14: the QA tenant's own JWT could read ALL 4
/// existing tenants' full rows (client_name, company_name, location_name)
/// with a plain unfiltered SELECT. Same class of bug as migration 185's
/// view-security-invoker fix, except here it's the root client/company/
/// location records themselves, not a report view. Fixed in migration 188
/// (auth_rw_<table> policies matching the JWT's own client_id/company_id
/// claims). Kept as a permanent test, not deleted after the one-time
/// verification, since a future migration could reintroduce a permissive
/// policy on these tables the same way 001 originally shipped one.
void main() {
  test('ric_clients/ric_companies/ric_locations: JWT sees ONLY its own tenant\'s rows', () async {
    final verifier = BackendVerifier();
    await verifier.login();

    final clients = await verifier.getUnscoped('ric_clients', {'select': 'id'});
    final companies = await verifier.getUnscoped('ric_companies', {'select': 'id,client_id'});
    final locations = await verifier.getUnscoped('ric_locations', {'select': 'id,client_id,company_id'});

    expect(clients.length, 1, reason: 'A tenant\'s JWT must see exactly its own ric_clients row, never another tenant\'s');
    expect(clients.first['id'], verifier.clientId);

    expect(companies.every((c) => c['client_id'] == verifier.clientId), isTrue,
        reason: 'Every visible ric_companies row must belong to this tenant\'s own client_id');

    expect(locations.every((l) => l['client_id'] == verifier.clientId && l['company_id'] == verifier.companyId), isTrue,
        reason: 'Every visible ric_locations row must belong to this tenant\'s own client_id+company_id');
  });
}
