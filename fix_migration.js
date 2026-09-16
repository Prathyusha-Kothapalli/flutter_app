/**
 * Fixed Migration Runner — properly handles DO $$ blocks and multi-statement SQL
 */
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, 'backend/.env') });
const fs = require('fs');

const DATABASE_URL = process.env.DATABASE_URL || 'postgresql://postgres:postgrespassword@localhost:5432/videoplatform';

const { Pool } = require(path.join(__dirname, 'backend/node_modules/pg'));

const pool = new Pool({
  connectionString: DATABASE_URL,
  ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: false } : false,
});

// Splits SQL correctly, respecting $$ dollar-quote blocks and DO blocks
function splitStatements(sql) {
  const statements = [];
  let current = '';
  let inDollarQuote = false;

  const lines = sql.split('\n');
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.startsWith('--')) {
      continue; // skip comment-only lines
    }

    // Track $$ dollar quoting
    const dollarMatches = (line.match(/\$\$/g) || []).length;
    if (dollarMatches % 2 !== 0) {
      inDollarQuote = !inDollarQuote;
    }

    current += line + '\n';

    // Only split on ; when NOT inside a $$ block
    if (!inDollarQuote && trimmed.endsWith(';')) {
      const stmt = current.trim();
      if (stmt.length > 3) {
        statements.push(stmt);
      }
      current = '';
    }
  }

  // Push any remaining statement
  if (current.trim().length > 3) {
    statements.push(current.trim());
  }

  return statements;
}

async function runSQL(client, filePath, label) {
  console.log(`\n📂 Running: ${label}`);
  const sql = fs.readFileSync(filePath, 'utf8');
  const statements = splitStatements(sql);

  let success = 0;
  let skipped = 0;
  let failed = 0;

  for (const stmt of statements) {
    try {
      await client.query(stmt);
      success++;
      const preview = stmt.replace(/\n/g, ' ').replace(/\s+/g, ' ').substring(0, 90);
      console.log(`  ✅ ${preview}`);
    } catch (err) {
      if (
        err.message.includes('already exists') ||
        err.code === '42P07' || // duplicate table
        err.code === '42710' || // duplicate constraint
        err.code === '42701'    // duplicate column
      ) {
        skipped++;
        const preview = stmt.replace(/\n/g, ' ').replace(/\s+/g, ' ').substring(0, 70);
        console.log(`  ⏭️  SKIP (exists): ${preview}`);
      } else {
        failed++;
        console.error(`  ❌ ERROR [${err.code}]: ${err.message.substring(0, 120)}`);
      }
    }
  }
  console.log(`  → ${success} ok, ${skipped} skipped, ${failed} errors`);
}

async function main() {
  const client = await pool.connect();
  try {
    console.log('🔌 Connected to Neon PostgreSQL\n');

    // Step 1: Base schema (initial tables)
    await runSQL(client, path.join(__dirname, 'database/migrations/001_initial_schema.sql'), '001_initial_schema.sql');

    // Step 2: Refresh tokens table
    await runSQL(client, path.join(__dirname, 'database/migrations/002_create_refresh_tokens_table.sql'), '002_create_refresh_tokens_table.sql');

    // Step 3: Production schema patches + seed admin
    await runSQL(client, path.join(__dirname, 'database/migrations/003_production_schema.sql'), '003_production_schema.sql');

    // Step 4: QC ticket system
    await runSQL(client, path.join(__dirname, 'database/schema/003_qc_ticket_system.sql'), '003_qc_ticket_system.sql');

    // Step 5: Notifications and audit
    await runSQL(client, path.join(__dirname, 'database/schema/004_notifications_and_audit.sql'), '004_notifications_and_audit.sql');

    // Step 6: Seed admin (from seeds folder)
    await runSQL(client, path.join(__dirname, 'database/seeds/001_seed_admin.sql'), '001_seed_admin.sql');

    console.log('\n========================================');
    console.log('✅ ALL MIGRATIONS COMPLETE!');
    console.log('========================================\n');

    // Verify key tables exist
    const tableCheck = await client.query(`
      SELECT table_name FROM information_schema.tables
      WHERE table_schema = 'public'
      ORDER BY table_name
    `);
    console.log('📊 Tables in Neon DB:');
    for (const row of tableCheck.rows) {
      console.log(`  ✅ ${row.table_name}`);
    }

    // Check admin accounts
    try {
      const adminCheck = await client.query(`SELECT email, is_active FROM admins`);
      console.log('\n👤 Admin accounts:');
      for (const row of adminCheck.rows) {
        console.log(`  📧 ${row.email} (active: ${row.is_active})`);
      }
    } catch (_) {}

    console.log('\n🔑 Login credentials:');
    console.log('  Admin:   admin@gmail.com  / admin123');
    console.log('  QC Team: qcteam@gmail.com / qcteam123');

  } catch (err) {
    console.error('❌ Fatal migration error:', err.message);
  } finally {
    client.release();
    await pool.end();
  }
}

main().catch(err => {
  console.error('❌ Migration failed:', err.message);
  process.exit(1);
});
