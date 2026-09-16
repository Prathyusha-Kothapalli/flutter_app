const path = require('path');
const { Pool } = require(path.join(__dirname, '../backend/node_modules/pg'));
const bcrypt = require(path.join(__dirname, '../backend/node_modules/bcryptjs'));

const pool = new Pool({
  connectionString: 'postgresql://neondb_owner:npg_mDwP3Vlr1XCe@ep-small-wildflower-b4kk195a-pooler.c-6.us-east-2.aws.neon.tech/neondb?sslmode=require&channel_binding=require',
  ssl: { rejectUnauthorized: false },
});

async function seedAccounts() {
  const hashAdmin123 = await bcrypt.hash('admin123', 10);
  const hashPassword = await bcrypt.hash('password', 10);

  // Set admin123 for admins
  await pool.query('UPDATE admins SET password_hash = $1 WHERE email = $2', [hashAdmin123, 'admin@videoplatform.com']);
  await pool.query('UPDATE users SET password_hash = $1 WHERE email = $2', [hashAdmin123, 'admin@videoplatform.com']);

  // Insert admin@gmail.com
  await pool.query(
    `INSERT INTO admins (id, email, password_hash, full_name, username, is_active)
     VALUES ('00000000-0000-0000-0000-000000000099', 'admin@gmail.com', $1, 'Super Admin', 'admin_gmail', TRUE)
     ON CONFLICT (email) DO UPDATE SET password_hash = $1`,
    [hashAdmin123]
  );

  await pool.query(
    `INSERT INTO users (id, email, password_hash, full_name, role, is_active)
     VALUES ('00000000-0000-0000-0000-000000000099', 'admin@gmail.com', $1, 'Super Admin', 'admin', TRUE)
     ON CONFLICT (email) DO UPDATE SET password_hash = $1`,
    [hashAdmin123]
  );

  // Set qc123 for qc reviewer
  const hashQC = await bcrypt.hash('qc123', 10);
  await pool.query('UPDATE users SET password_hash = $1 WHERE email = $2', [hashQC, 'qc@videoplatform.com']);

  // Set vendor123 for vendor
  const hashVendor = await bcrypt.hash('vendor123', 10);
  await pool.query('UPDATE vendors SET password_hash = $1 WHERE email = $2', [hashVendor, 'vendor@videoplatform.com']);
  await pool.query('UPDATE users SET password_hash = $1 WHERE email = $2', [hashVendor, 'vendor@videoplatform.com']);

  // Set candidate123 for candidate
  const hashCandidate = await bcrypt.hash('candidate123', 10);
  await pool.query('UPDATE candidates SET password_hash = $1 WHERE email = $2', [hashCandidate, 'candidate@videoplatform.com']);
  await pool.query('UPDATE users SET password_hash = $1 WHERE email = $2', [hashCandidate, 'candidate@videoplatform.com']);

  console.log('✅ Accounts updated successfully!');
  await pool.end();
  process.exit(0);
}

seedAccounts().catch((err) => {
  console.error(err);
  process.exit(1);
});
