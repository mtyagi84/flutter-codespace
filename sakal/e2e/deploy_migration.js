const { Client } = require('pg');
require('./helpers/env');
const fs = require('fs');
const filePath = process.argv[2];
(async () => {
  const client = new Client({
    connectionString: process.env.SAKAL_DEV_DB_URL,
    ssl: { rejectUnauthorized: false }
  });
  await client.connect();
  const sql = fs.readFileSync(filePath, 'utf8');
  try {
    await client.query(sql);
    console.log('Migration applied successfully:', filePath);
  } catch (e) {
    console.error('MIGRATION ERROR:', e.message);
    console.error('Detail:', e.detail || '');
    console.error('Position:', e.position || '');
    process.exit(1);
  }
  await client.end();
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
