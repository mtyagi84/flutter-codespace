// Loads e2e/.env (gitignored, real credentials) into process.env so test/
// setup scripts never carry a hardcoded DB password in source. Safe to
// require from any script at any depth — resolves relative to this file,
// not the caller's cwd. No-ops quietly if .env doesn't exist yet (e.g. a
// fresh checkout before the developer creates one from .env.example).
const path = require('path');
try {
  process.loadEnvFile(path.join(__dirname, '..', '.env'));
} catch (_) {
  // .env missing or Node too old for loadEnvFile — scripts that need
  // SAKAL_DEV_DB_URL will fail with a clear "undefined" connection error
  // rather than silently using a stale hardcoded value.
}
