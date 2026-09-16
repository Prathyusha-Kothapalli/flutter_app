/**
 * Production Schema Migration Runner — self-contained
 * Runs 003_production_schema.sql against PostgreSQL
 */
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '../backend/.env') });
const fs = require('fs');

const DATABASE_URL = process.env.DATABASE_URL || 'postgresql://postgres:postgrespassword@localhost:5432/videoplatform';

// Use pg from backend node_modules
const { Pool } = require(path.join(__dirname, '../backend/node_modules/pg'));

const pool = new Pool({
  connectionString: DATABASE_URL,
  ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: false } : false,
});

async function runMigration() {
  const sqlPath = path.join(__dirname, 'migrations/003_production_schema.sql');
  const sql = fs.readFileSync(sqlPath, 'utf8');

  const client = await pool.connect();
  try {
    console.log('🔌 Connected to Neon PostgreSQL');
    console.log('🚀 Running 003_production_schema.sql migration...\n');

    // Execute the whole file as a single transaction
    await client.query('BEGIN');
    
    const statements = sql
      .split(';')
      .map(s => s.trim())
      .filter(s => s.length > 3 && !s.startsWith('--'));

    let successCount = 0;
    let skipCount = 0;

    for (const stmt of statements) {
      try {
        await client.query(stmt);
        successCount++;
        const preview = stmt.replace(/\n/g, ' ').substring(0, 80);
        console.log(`  ✅ ${preview}`);
      } catch (err) {
        if (
          err.message.includes('already exists') ||
          err.message.includes('does not exist') ||
          err.code === '42P07' || // duplicate table
          err.code === '42710' || // duplicate constraint
          err.code === '42701'    // duplicate column
        ) {
          skipCount++;
          const preview = stmt.replace(/\n/g, ' ').substring(0, 60);
          console.log(`  ⏭️  SKIP: ${preview}`);
        } else {
          console.error(`  ❌ ERROR [${err.code}]: ${err.message}`);
          console.error(`     Stmt: ${stmt.substring(0, 100)}`);
        }
      }
    }

    await client.query('COMMIT');
    console.log(`\n✅ Migration complete — ${successCount} executed, ${skipCount} skipped`);

    // Verification checks
    const tableCheck = await client.query(`
      SELECT table_name FROM information_schema.tables
      WHERE table_schema = 'public'
        AND table_name IN ('notifications','qc_tickets','ticket_assignments','reviewer_activity','admin_qc_configs','users','refresh_tokens')
      ORDER BY table_name
    `);
    console.log('\n📊 Production tables verified:');
    for (const row of tableCheck.rows) {
      console.log(`  ✅ ${row.table_name}`);
    }

    const adminCheck = await client.query(`SELECT email FROM admins WHERE email = 'admin@gmail.com'`);
    if (adminCheck.rowCount > 0) {
      console.log(`\n✅ Admin account: admin@gmail.com / admin123`);
    }

    const qcCheck = await client.query(`SELECT reviewer_email FROM reviewer_activity WHERE reviewer_email = 'qcteam@gmail.com'`);
    if (qcCheck.rowCount > 0) {
      console.log(`✅ QC account: qcteam@gmail.com / qcteam123`);
    }

  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
    await pool.end();
  }
}

runMigration().catch(err => {
  console.error('❌ Migration failed:', err.message);
  process.exit(1);
});
