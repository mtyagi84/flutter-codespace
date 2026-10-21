const { Client } = require('pg');
require('./helpers/env');
const oid = process.argv[2];
(async () => {
  const client = new Client({
    connectionString: process.env.SAKAL_DEV_DB_URL,
    ssl: { rejectUnauthorized: false }
  });
  await client.connect();
  const r = await client.query(`SELECT pg_get_functiondef($1::oid) as def`, [oid]);
  console.log(r.rows[0].def);
  await client.end();
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
