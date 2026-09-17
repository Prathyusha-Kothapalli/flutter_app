const db = require('./src/database/connection');

async function patch() {
  try {
    console.log('Connecting to database...');
    // 1. Notifications table check & patch
    await db.query(`
      ALTER TABLE notifications ADD COLUMN IF NOT EXISTS type VARCHAR(100);
      ALTER TABLE notifications ALTER COLUMN type DROP NOT NULL;
      ALTER TABLE notifications ADD COLUMN IF NOT EXISTS role VARCHAR(50);
      ALTER TABLE notifications ALTER COLUMN role DROP NOT NULL;
      ALTER TABLE notifications ADD COLUMN IF NOT EXISTS user_role VARCHAR(50) DEFAULT 'candidate';
      ALTER TABLE notifications ALTER COLUMN user_role DROP NOT NULL;
    `);
    console.log('✅ notifications table patched');

    // 2. qc_reviews foreign key drop
    await db.query(`
      ALTER TABLE qc_reviews DROP CONSTRAINT IF EXISTS qc_reviews_reviewer_id_fkey;
      ALTER TABLE qc_reviews DROP CONSTRAINT IF EXISTS fk_qc_reviews_reviewer;
    `);
    console.log('✅ qc_reviews foreign key dropped');

    console.log('Database patching complete!');
    process.exit(0);
  } catch (err) {
    console.error('Patch error:', err);
    process.exit(1);
  }
}

patch();
