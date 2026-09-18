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

    // 3. qc_tickets table structure patch
    await db.query(`
      CREATE TABLE IF NOT EXISTS qc_tickets (
        id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
        ticket_code VARCHAR(50) NOT NULL UNIQUE,
        video_id VARCHAR(100) NOT NULL,
        candidate_id VARCHAR(100),
        vendor_id VARCHAR(100),
        project_id VARCHAR(100) DEFAULT 'PRJ-DEFAULT',
        upload_date TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        status VARCHAR(50) NOT NULL DEFAULT 'pending_qc',
        assigned_reviewer_id VARCHAR(100),
        assigned_reviewer_name VARCHAR(255),
        assignment_time TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        deleted_at TIMESTAMP WITH TIME ZONE NULL
      );
      ALTER TABLE qc_tickets ADD COLUMN IF NOT EXISTS upload_date TIMESTAMP WITH TIME ZONE DEFAULT NOW();
      ALTER TABLE qc_tickets ADD COLUMN IF NOT EXISTS project_id VARCHAR(100) DEFAULT 'PRJ-DEFAULT';
      ALTER TABLE qc_tickets ADD COLUMN IF NOT EXISTS assigned_reviewer_id VARCHAR(100);
      ALTER TABLE qc_tickets ADD COLUMN IF NOT EXISTS assigned_reviewer_name VARCHAR(255);
      ALTER TABLE qc_tickets ADD COLUMN IF NOT EXISTS assigned_at TIMESTAMP WITH TIME ZONE DEFAULT NOW();
      ALTER TABLE qc_tickets ADD COLUMN IF NOT EXISTS assignment_time TIMESTAMP WITH TIME ZONE DEFAULT NOW();
      ALTER TABLE qc_tickets ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP WITH TIME ZONE NULL;
    `);
    console.log('✅ qc_tickets table patched');

    // 4. reviewer_activity table patch
    await db.query(`
      CREATE TABLE IF NOT EXISTS reviewer_activity (
        reviewer_id VARCHAR(100) PRIMARY KEY,
        reviewer_name VARCHAR(255) NOT NULL,
        reviewer_email VARCHAR(255) NOT NULL,
        is_active BOOLEAN NOT NULL DEFAULT TRUE,
        is_available BOOLEAN NOT NULL DEFAULT TRUE,
        last_login_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        last_dashboard_activity_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        last_review_submission_at TIMESTAMP WITH TIME ZONE NULL,
        last_active_timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      );
    `);
    console.log('✅ reviewer_activity table patched');

    // 5. ticket_assignments table patch
    await db.query(`
      CREATE TABLE IF NOT EXISTS ticket_assignments (
        id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
        ticket_id UUID NOT NULL REFERENCES qc_tickets(id) ON DELETE CASCADE,
        video_id VARCHAR(100),
        previous_reviewer_id VARCHAR(100),
        previous_reviewer_name VARCHAR(255),
        new_reviewer_id VARCHAR(100) NOT NULL,
        new_reviewer_name VARCHAR(255) NOT NULL,
        assignment_time TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        reassignment_time TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        reason VARCHAR(100) NOT NULL DEFAULT 'INITIAL_ASSIGNMENT',
        performed_by VARCHAR(100) NOT NULL DEFAULT 'SYSTEM',
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      );
      ALTER TABLE ticket_assignments ADD COLUMN IF NOT EXISTS video_id VARCHAR(100);
      ALTER TABLE ticket_assignments ADD COLUMN IF NOT EXISTS previous_reviewer_id VARCHAR(100);
      ALTER TABLE ticket_assignments ADD COLUMN IF NOT EXISTS previous_reviewer_name VARCHAR(255);
      ALTER TABLE ticket_assignments ADD COLUMN IF NOT EXISTS new_reviewer_id VARCHAR(100);
      ALTER TABLE ticket_assignments ADD COLUMN IF NOT EXISTS new_reviewer_name VARCHAR(255);
      ALTER TABLE ticket_assignments ADD COLUMN IF NOT EXISTS assignment_time TIMESTAMP WITH TIME ZONE DEFAULT NOW();
      ALTER TABLE ticket_assignments ADD COLUMN IF NOT EXISTS reassignment_time TIMESTAMP WITH TIME ZONE DEFAULT NOW();
      ALTER TABLE ticket_assignments ADD COLUMN IF NOT EXISTS reason VARCHAR(100) DEFAULT 'INITIAL_ASSIGNMENT';
      ALTER TABLE ticket_assignments ADD COLUMN IF NOT EXISTS performed_by VARCHAR(100) DEFAULT 'SYSTEM';
      ALTER TABLE ticket_assignments ALTER COLUMN reviewer_id DROP NOT NULL;
    `);
    console.log('✅ ticket_assignments table patched');

    console.log('Database patching complete!');
    process.exit(0);
  } catch (err) {
    console.error('Patch error:', err);
    process.exit(1);
  }
}

patch();
