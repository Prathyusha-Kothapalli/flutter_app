const path = require('path');
require('dotenv').config({ path: path.join(__dirname, 'backend/.env') });
const bcrypt = require(path.join(__dirname, 'backend/node_modules/bcryptjs'));
const { Pool } = require(path.join(__dirname, 'backend/node_modules/pg'));

const pool = new Pool({
  connectionString: process.env.DATABASE_URL || 'postgresql://postgres:postgrespassword@localhost:5432/videoplatform',
  ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: false } : false,
});

async function fixAdminPasswords() {
  const hash = await bcrypt.hash('admin123', 10);
  console.log('Generated hash:', hash);

  // Fix all admin accounts
  const r1 = await pool.query(
    `UPDATE admins SET password_hash = $1, is_active = TRUE WHERE email IN ('admin@gmail.com', 'admin@example.com')`,
    [hash]
  );
  console.log(`✅ Updated ${r1.rowCount} admin account(s) with new password hash`);

  // Also fix QC team reviewer password
  const qcHash = await bcrypt.hash('qcteam123', 10);
  const r2 = await pool.query(
    `UPDATE reviewer_activity SET password_hash = $1 WHERE reviewer_email = 'qcteam@gmail.com'`,
    [qcHash]
  );
  console.log(`✅ Updated ${r2.rowCount} QC reviewer account(s)`);

  // List all admins
  const admins = await pool.query(`SELECT email, is_active, full_name FROM admins`);
  console.log('\n👤 Admin accounts in DB:');
  for (const row of admins.rows) {
    console.log(`  📧 ${row.email} | active: ${row.is_active} | name: ${row.full_name}`);
  }

  console.log('\n🔑 Working credentials:');
  console.log('  Admin:   admin@gmail.com    / admin123');
  console.log('  Admin:   admin@example.com  / admin123');
  console.log('  QC Team: qcteam@gmail.com   / qcteam123');

  await pool.end();
}

fixAdminPasswords().catch(err => {
  console.error('Error:', err.message);
  pool.end();
});
