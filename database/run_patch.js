/**
 * Quick Patch Runner — runs individual ALTER statements outside a transaction
 * so each can fail independently without aborting the rest.
 */
const path = require('path');
const { Pool } = require(path.join(__dirname, '../backend/node_modules/pg'));

const DATABASE_URL = process.env.DATABASE_URL || 'postgresql://neondb_owner:npg_mDwP3Vlr1XCe@ep-small-wildflower-b4kk195a-pooler.c-6.us-east-2.aws.neon.tech/neondb?sslmode=require&channel_binding=require';

const pool = new Pool({
  connectionString: DATABASE_URL,
  ssl: { rejectUnauthorized: false },
});

const patches = [
  // 1. Drop old videos status constraint and recreate with all operational values
  `ALTER TABLE videos DROP CONSTRAINT IF EXISTS chk_videos_status`,
  `ALTER TABLE videos ADD CONSTRAINT chk_videos_status CHECK (
    status IN (
      'pending','uploaded','under_review',
      'pending_qc','assigned_qc','in_review',
      'qc_approved','qc_rejected',
      'approved','rejected',
      'PENDING_QC','ASSIGNED_QC','IN_REVIEW',
      'QC_APPROVED','QC_REJECTED',
      'APPROVED','REJECTED'
    )
  )`,

  // 2. Add amount column to payments
  `ALTER TABLE payments ADD COLUMN IF NOT EXISTS amount DECIMAL(12,2) DEFAULT 0`,

  // 3. Drop NOT NULL from payments schema columns so simple INSERT works
  `ALTER TABLE payments ALTER COLUMN hourly_rate DROP NOT NULL`,
  `ALTER TABLE payments ALTER COLUMN total_amount DROP NOT NULL`,
  `ALTER TABLE payments ALTER COLUMN approved_seconds DROP NOT NULL`,
  `ALTER TABLE payments ALTER COLUMN approved_hours DROP NOT NULL`,

  // 4. Add score columns to qc_reviews
  `ALTER TABLE qc_reviews ADD COLUMN IF NOT EXISTS qc_reviewer_id  UUID`,
  `ALTER TABLE qc_reviews ADD COLUMN IF NOT EXISTS audio_score     DECIMAL(4,2) DEFAULT 0`,
  `ALTER TABLE qc_reviews ADD COLUMN IF NOT EXISTS lighting_score  DECIMAL(4,2) DEFAULT 0`,
  `ALTER TABLE qc_reviews ADD COLUMN IF NOT EXISTS framing_score   DECIMAL(4,2) DEFAULT 0`,
  `ALTER TABLE qc_reviews ADD COLUMN IF NOT EXISTS env_match_score DECIMAL(4,2) DEFAULT 0`,
  `ALTER TABLE qc_reviews ADD COLUMN IF NOT EXISTS qc_comments     TEXT`,
  `ALTER TABLE qc_reviews ADD COLUMN IF NOT EXISTS admin_comments  TEXT`,

  // 5. Drop old qc_reviews status constraint and recreate
  `ALTER TABLE qc_reviews DROP CONSTRAINT IF EXISTS chk_qc_reviews_status`,
  // 5b. Ensure reviewer_activity has activity timestamp columns
  `ALTER TABLE reviewer_activity ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT TRUE`,
  `ALTER TABLE reviewer_activity ADD COLUMN IF NOT EXISTS is_available BOOLEAN DEFAULT TRUE`,
  `ALTER TABLE reviewer_activity ADD COLUMN IF NOT EXISTS last_login_at TIMESTAMPTZ DEFAULT NOW()`,
  `ALTER TABLE reviewer_activity ADD COLUMN IF NOT EXISTS last_dashboard_activity_at TIMESTAMPTZ DEFAULT NOW()`,
  `ALTER TABLE reviewer_activity ADD COLUMN IF NOT EXISTS last_review_submission_at TIMESTAMPTZ`,
  `ALTER TABLE reviewer_activity ADD COLUMN IF NOT EXISTS last_active_timestamp TIMESTAMPTZ DEFAULT NOW()`,
  `ALTER TABLE reviewer_activity ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW()`,

  // 6. Add password_hash to candidates
  `ALTER TABLE candidates ADD COLUMN IF NOT EXISTS password_hash VARCHAR(255)`,

  // 7. Ensure users table has vendor_id and created_by columns
  `ALTER TABLE users ADD COLUMN IF NOT EXISTS vendor_id   UUID`,
  `ALTER TABLE users ADD COLUMN IF NOT EXISTS created_by  UUID`,

  // 8. Upsert admin account with correct bcrypt hash for admin123
  `INSERT INTO admins (id, email, password_hash, full_name, username, is_active, created_at, updated_at)
   VALUES (
     '00000000-0000-0000-0000-000000000001',
     'admin@gmail.com',
     '$2a$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi',
     'System Administrator',
     'admin',
     TRUE,
     NOW(),
     NOW()
   ) ON CONFLICT (email) DO UPDATE
       SET password_hash = '$2a$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi',
           full_name = 'System Administrator',
           is_active = TRUE,
           updated_at = NOW()`,

  // 9. Ensure refresh_tokens table exists
  `CREATE TABLE IF NOT EXISTS refresh_tokens (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL,
    token TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_refresh_tokens_token UNIQUE (token)
  )`,

  // 11. Drop NOT NULL on candidate_id and vendor_id in videos for fallback safety
  `ALTER TABLE videos ALTER COLUMN candidate_id DROP NOT NULL`,
  `ALTER TABLE videos ALTER COLUMN vendor_id DROP NOT NULL`,
  `ALTER TABLE videos ADD COLUMN IF NOT EXISTS rejection_reason TEXT`,

  // 12. Seed default system vendor
  `INSERT INTO vendors (id, vendor_code, company_name, contact_person, email, password_hash, is_active, created_at, updated_at)
   VALUES (
     '00000000-0000-0000-0000-000000000003',
     'VENDOR001',
     'Apex Video Solutions',
     'Vendor Manager',
     'vendor@videoplatform.com',
     '$2a$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi',
     TRUE, NOW(), NOW()
   ) ON CONFLICT (email) DO UPDATE
       SET vendor_code = 'VENDOR001',
           company_name = 'Apex Video Solutions',
           password_hash = '$2a$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi',
           is_active = TRUE,
           updated_at = NOW()`,

  // 13. Seed default system candidate
  `INSERT INTO candidates (id, vendor_id, full_name, email, phone, password_hash, is_active, created_at, updated_at)
   VALUES (
     '00000000-0000-0000-0000-000000000002',
     '00000000-0000-0000-0000-000000000003',
     'John Candidate',
     'candidate@videoplatform.com',
     '+19876543210',
     '$2a$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi',
     TRUE, NOW(), NOW()
   ) ON CONFLICT (email) DO UPDATE
       SET full_name = 'John Candidate',
           phone = '+19876543210',
           password_hash = '$2a$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi',
           is_active = TRUE,
           updated_at = NOW()`,

  // 14. Ensure unified users table exists for role-based authentication
  `CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    full_name VARCHAR(200),
    role VARCHAR(50) NOT NULL DEFAULT 'candidate',
    vendor_id UUID,
    created_by UUID,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
  )`,

  // 15. Upsert unified admin users into admins and users table
  `INSERT INTO admins (id, email, password_hash, full_name, username, is_active, created_at, updated_at)
   VALUES (
     '00000000-0000-0000-0000-000000000001',
     'admin@videoplatform.com',
     '$2a$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi',
     'System Administrator',
     'admin',
     TRUE, NOW(), NOW()
   ) ON CONFLICT (email) DO UPDATE
       SET password_hash = '$2a$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi',
           full_name = 'System Administrator',
           is_active = TRUE,
           updated_at = NOW()`,

  `INSERT INTO users (id, email, password_hash, full_name, role, is_active, created_at, updated_at)
   VALUES (
     '00000000-0000-0000-0000-000000000001',
     'admin@videoplatform.com',
     '$2a$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi',
     'System Administrator',
     'admin',
     TRUE, NOW(), NOW()
   ) ON CONFLICT (email) DO UPDATE
       SET password_hash = '$2a$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi',
           role = 'admin',
           is_active = TRUE,
           updated_at = NOW()`,

  `INSERT INTO users (id, email, password_hash, full_name, role, is_active, created_at, updated_at)
   VALUES (
     '00000000-0000-0000-0000-000000000005',
     'admin@gmail.com',
     '$2a$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi',
     'System Administrator',
     'admin',
     TRUE, NOW(), NOW()
   ) ON CONFLICT (email) DO UPDATE
       SET password_hash = '$2a$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi',
           role = 'admin',
           is_active = TRUE,
           updated_at = NOW()`,

  // 16. Upsert dedicated QC Team accounts into users table
  `INSERT INTO users (id, email, password_hash, full_name, role, is_active, created_at, updated_at)
   VALUES (
     '00000000-0000-0000-0000-000000000004',
     'qc@videoplatform.com',
     '$2a$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi',
     'QC Team Lead',
     'qc_team',
     TRUE, NOW(), NOW()
   ) ON CONFLICT (email) DO UPDATE
       SET password_hash = '$2a$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi',
           role = 'qc_team',
           is_active = TRUE,
           updated_at = NOW()`,

  `INSERT INTO users (id, email, password_hash, full_name, role, is_active, created_at, updated_at)
   VALUES (
     '00000000-0000-0000-0000-000000000006',
     'qc@gmail.com',
     '$2a$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi',
     'QC Team Lead',
     'qc_team',
     TRUE, NOW(), NOW()
   ) ON CONFLICT (email) DO UPDATE
       SET password_hash = '$2a$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi',
           role = 'qc_team',
           is_active = TRUE,
           updated_at = NOW()`,
];

async function runPatches() {
  const client = await pool.connect();
  console.log('🔌 Connected to Neon PostgreSQL');
  console.log('🔧 Running individual patches...\n');

  let ok = 0; let skip = 0; let fail = 0;
  for (const sql of patches) {
    const preview = sql.replace(/\n/g, ' ').replace(/\s+/g, ' ').substring(0, 80);
    try {
      await client.query(sql);
      console.log(`  ✅ ${preview}`);
      ok++;
    } catch (err) {
      if (
        err.message.includes('already exists') ||
        err.message.includes('does not exist') ||
        err.code === '42701' || // duplicate column
        err.code === '42710' || // duplicate constraint
        err.code === '23505'    // unique violation
      ) {
        console.log(`  ⏭️  SKIP: ${preview}`);
        skip++;
      } else {
        console.error(`  ❌ FAIL [${err.code}]: ${err.message.substring(0, 100)}`);
        fail++;
      }
    }
  }

  console.log(`\n✅ Done — ${ok} applied, ${skip} skipped, ${fail} failed`);

  // Final verification
  console.log('\n📊 Key table column check:');

  const videosCheck = await client.query(`
    SELECT constraint_name FROM information_schema.table_constraints
    WHERE table_name='videos' AND constraint_name='chk_videos_status'
  `);
  console.log(`  videos.chk_videos_status: ${videosCheck.rowCount > 0 ? '✅ present' : '❌ missing'}`);

  const payColCheck = await client.query(`
    SELECT column_name FROM information_schema.columns
    WHERE table_name='payments' AND column_name='amount'
  `);
  console.log(`  payments.amount column:   ${payColCheck.rowCount > 0 ? '✅ present' : '❌ missing'}`);

  const qcColCheck = await client.query(`
    SELECT column_name FROM information_schema.columns
    WHERE table_name='qc_reviews' AND column_name='audio_score'
  `);
  console.log(`  qc_reviews.audio_score:   ${qcColCheck.rowCount > 0 ? '✅ present' : '❌ missing'}`);

  const adminCheck = await client.query(`SELECT email FROM admins WHERE email='admin@gmail.com'`);
  console.log(`  admin@gmail.com account:  ${adminCheck.rowCount > 0 ? '✅ present' : '❌ missing'}`);

  client.release();
  await pool.end();
}

runPatches().catch(err => {
  console.error('Fatal:', err.message);
  process.exit(1);
});
