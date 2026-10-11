// Direct DB verification for tests that need to prove a transaction is
// actually correct, not just that the right text appeared on screen —
// see TEST_PLAN.md's own "Conventions for every phase". DATABASE_URL is
// never hardcoded or committed; it must be exported in the shell running
// the tests (same session-scoped, re-paste-each-time convention used for
// every other direct-DB script in this project).
const { Client } = require('pg');

async function withDb(fn) {
  if (!process.env.DATABASE_URL) {
    throw new Error('DATABASE_URL is not set — export it before running DB-verifying tests.');
  }
  const client = new Client({ connectionString: process.env.DATABASE_URL, ssl: { rejectUnauthorized: false } });
  await client.connect();
  try {
    return await fn(client);
  } finally {
    await client.end();
  }
}

module.exports = { withDb };
