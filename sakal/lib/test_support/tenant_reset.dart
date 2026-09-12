import 'backend_verifier.dart';

/// Resets the QA tenant back to a clean slate before a pilot run, by calling
/// `fn_reset_qa_tenant()` — a wrapper RPC around reset_all_transactions.sql's
/// exact logic (see sakal/backend/scripts/create_qa_reset_function.sql).
///
/// This exists only because there's no direct Postgres connection available
/// to this test harness (locked decision: PostgREST + JWT only, no
/// service-role key) — an RPC call is the sole way to trigger a
/// multi-table admin operation like this from Dart test code. Safety comes
/// from the RPC itself taking no parameters and hardcoding the QA tenant's
/// own IDs internally — this call cannot be pointed at any other tenant no
/// matter what.
///
/// Requires [BackendVerifier.login] to have already been called (needs a
/// valid JWT, same as any other authenticated PostgREST call).
Future<void> resetQaTenant(BackendVerifier verifier) async {
  await verifier.rpc('fn_reset_qa_tenant', const {});
}
