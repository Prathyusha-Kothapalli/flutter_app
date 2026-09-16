/**
 * Database Reset & Clean Schema Generator
 * Drops all legacy tables and recreates a 100% clean, fresh production PostgreSQL schema.
 */

const path = require('path');
const { Pool } = require(path.join(__dirname, '../backend/node_modules/pg'));

const DATABASE_URL = process.env.DATABASE_URL || 'postgresql://neondb_owner:npg_mDwP3Vlr1XCe@ep-small-wildflower-b4kk195a-pooler.c-6.us-east-2.aws.neon.tech/neondb?sslmode=require&channel_binding=require';

const pool = new Pool({
  connectionString: DATABASE_URL,
  ssl: { rejectUnauthorized: false },
});

const resetScript = `
-- 1. Enable UUID Extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 2. Dynamically drop EVERY table in the public schema (removes all orphan & legacy tables like otp_logs, payment_transactions)
DO $$ DECLARE
    r RECORD;
BEGIN
    FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP
        EXECUTE 'DROP TABLE IF EXISTS public.' || quote_ident(r.tablename) || ' CASCADE';
    END LOOP;
END $$;

-- 3. Create Unified Users Table (role-based auth)
CREATE TABLE users (
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
);

-- 4. Create Admins Table
CREATE TABLE admins (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    username VARCHAR(100),
    email VARCHAR(255) UNIQUE NOT NULL,
    phone VARCHAR(20),
    password_hash VARCHAR(255) NOT NULL,
    full_name VARCHAR(200) NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    last_login_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

-- 5. Create Vendors Table
CREATE TABLE vendors (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    vendor_code VARCHAR(50) UNIQUE NOT NULL,
    company_name VARCHAR(200) NOT NULL,
    contact_person VARCHAR(200) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    phone VARCHAR(20),
    address TEXT,
    password_hash VARCHAR(255),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_by UUID REFERENCES admins(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

-- 6. Create Candidates Table
CREATE TABLE candidates (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    vendor_id UUID REFERENCES vendors(id) ON DELETE CASCADE,
    full_name VARCHAR(200) NOT NULL,
    email VARCHAR(255),
    phone VARCHAR(20) NOT NULL,
    password_hash VARCHAR(255),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

-- 7. Create User Sessions Table
CREATE TABLE user_sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    candidate_id UUID REFERENCES candidates(id) ON DELETE CASCADE,
    token VARCHAR(500) UNIQUE NOT NULL,
    device_info VARCHAR(500),
    ip_address VARCHAR(45),
    expires_at TIMESTAMPTZ NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

-- 8. Create Videos Table
CREATE TABLE videos (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    candidate_id UUID REFERENCES candidates(id) ON DELETE CASCADE,
    vendor_id UUID REFERENCES vendors(id) ON DELETE CASCADE,
    title VARCHAR(255),
    description TEXT,
    s3_url VARCHAR(1000),
    file_name VARCHAR(500),
    local_path VARCHAR(1000),
    file_size BIGINT CHECK (file_size IS NULL OR file_size >= 0),
    duration INTEGER CHECK (duration IS NULL OR duration >= 0),
    recording_date TIMESTAMPTZ,
    upload_date TIMESTAMPTZ,
    status VARCHAR(50) NOT NULL DEFAULT 'PENDING_QC',
    environment_tag VARCHAR(100),
    rejection_reason TEXT,
    latitude DECIMAL(10, 8),
    longitude DECIMAL(11, 8),
    device_id VARCHAR(255),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ,
    CONSTRAINT chk_videos_status CHECK (
      status IN (
        'pending','uploaded','under_review',
        'pending_qc','assigned_qc','in_review',
        'qc_approved','qc_rejected',
        'approved','rejected',
        'PENDING_QC','ASSIGNED_QC','IN_REVIEW',
        'QC_APPROVED','QC_REJECTED',
        'APPROVED','REJECTED'
      )
    )
);

-- 9. Create Video Locations Table
CREATE TABLE video_locations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    video_id UUID UNIQUE NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
    latitude DECIMAL(10, 8),
    longitude DECIMAL(11, 8),
    address TEXT,
    city VARCHAR(100),
    state VARCHAR(100),
    country VARCHAR(100),
    pincode VARCHAR(20),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

-- 10. Create QC Reviews Table
CREATE TABLE qc_reviews (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    video_id UUID UNIQUE NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
    reviewer_id UUID REFERENCES admins(id) ON DELETE SET NULL,
    reviewer_name VARCHAR(200),
    status VARCHAR(50) NOT NULL,
    reject_reason TEXT,
    audio_score DECIMAL(4,2) DEFAULT 0,
    lighting_score DECIMAL(4,2) DEFAULT 0,
    framing_score DECIMAL(4,2) DEFAULT 0,
    env_match_score DECIMAL(4,2) DEFAULT 0,
    qc_comments TEXT,
    admin_comments TEXT,
    reviewed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ,
    CONSTRAINT chk_qc_reviews_status CHECK (
      status IN ('approved','rejected','qc_approved','qc_rejected','QC_APPROVED','QC_REJECTED')
    )
);

-- 11. Create QC Tickets System Tables
CREATE TABLE qc_tickets (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ticket_code VARCHAR(50) UNIQUE NOT NULL,
    video_id UUID UNIQUE NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
    candidate_id UUID REFERENCES candidates(id) ON DELETE CASCADE,
    vendor_id UUID REFERENCES vendors(id) ON DELETE CASCADE,
    assigned_reviewer_id UUID,
    status VARCHAR(50) NOT NULL DEFAULT 'UNASSIGNED',
    priority VARCHAR(20) NOT NULL DEFAULT 'MEDIUM',
    assigned_at TIMESTAMPTZ,
    reviewed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE ticket_assignments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ticket_id UUID NOT NULL REFERENCES qc_tickets(id) ON DELETE CASCADE,
    reviewer_id UUID NOT NULL,
    assignment_reason VARCHAR(100) DEFAULT 'AUTO_LEAST_WORKLOAD',
    assigned_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    unassigned_at TIMESTAMPTZ
);

CREATE TABLE reviewer_activity (
    reviewer_id UUID PRIMARY KEY,
    reviewer_name VARCHAR(200),
    reviewer_email VARCHAR(255),
    assigned_count INT DEFAULT 0,
    completed_count INT DEFAULT 0,
    is_active BOOLEAN DEFAULT TRUE,
    is_available BOOLEAN DEFAULT TRUE,
    last_login_at TIMESTAMPTZ DEFAULT NOW(),
    last_dashboard_activity_at TIMESTAMPTZ DEFAULT NOW(),
    last_review_submission_at TIMESTAMPTZ,
    last_active_timestamp TIMESTAMPTZ DEFAULT NOW(),
    last_active_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE admin_qc_configs (
    key VARCHAR(100) PRIMARY KEY,
    value TEXT NOT NULL,
    description TEXT,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 12. Create Payments Table
CREATE TABLE payments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    vendor_id UUID REFERENCES vendors(id) ON DELETE CASCADE,
    candidate_id UUID REFERENCES candidates(id) ON DELETE CASCADE,
    amount DECIMAL(12,2) DEFAULT 0,
    hourly_rate DECIMAL(10,2),
    total_amount DECIMAL(12,2),
    approved_seconds INT,
    approved_hours DECIMAL(10,2),
    status VARCHAR(50) NOT NULL DEFAULT 'pending',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 13. Create Notifications Table
CREATE TABLE notifications (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID,
    role VARCHAR(50) NOT NULL,
    title VARCHAR(255) NOT NULL,
    message TEXT NOT NULL,
    video_id UUID,
    type VARCHAR(50) NOT NULL,
    color VARCHAR(20) DEFAULT '#2563EB',
    is_read BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 14. Create Audit Logs Table
CREATE TABLE audit_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    actor_id UUID NOT NULL,
    actor_role VARCHAR(50) NOT NULL,
    action VARCHAR(255) NOT NULL,
    resource_type VARCHAR(100),
    resource_id UUID,
    details JSONB,
    ip_address VARCHAR(45),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 15. Create Refresh Tokens Table
CREATE TABLE refresh_tokens (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL,
    token TEXT UNIQUE NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================================
-- SEED FRESH CLEAN INITIAL PRODUCTION DATA
-- ============================================================================

-- Seed System Vendor
INSERT INTO vendors (id, vendor_code, company_name, contact_person, email, password_hash, is_active, created_at, updated_at)
VALUES (
  '00000000-0000-0000-0000-000000000003',
  'VENDOR001',
  'Apex Video Solutions',
  'Vendor Manager',
  'vendor@videoplatform.com',
  '$2a$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi',
  TRUE, NOW(), NOW()
);

-- Seed System Candidate
INSERT INTO candidates (id, vendor_id, full_name, email, phone, password_hash, is_active, created_at, updated_at)
VALUES (
  '00000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000003',
  'John Candidate',
  'candidate@videoplatform.com',
  '+19876543210',
  '$2a$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi',
  TRUE, NOW(), NOW()
);

-- Seed Admins
INSERT INTO admins (id, email, password_hash, full_name, username, is_active, created_at, updated_at)
VALUES (
  '00000000-0000-0000-0000-000000000001',
  'admin@videoplatform.com',
  '$2a$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi',
  'System Administrator',
  'admin',
  TRUE, NOW(), NOW()
);

-- Seed Unified Users for Auth
INSERT INTO users (id, email, password_hash, full_name, role, vendor_id, is_active, created_at, updated_at)
VALUES 
  ('00000000-0000-0000-0000-000000000001', 'admin@videoplatform.com', '$2a$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', 'System Administrator', 'admin', NULL, TRUE, NOW(), NOW()),
  ('00000000-0000-0000-0000-000000000004', 'qc@videoplatform.com', '$2a$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', 'QC Team Lead', 'qc_team', NULL, TRUE, NOW(), NOW()),
  ('00000000-0000-0000-0000-000000000003', 'vendor@videoplatform.com', '$2a$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', 'Vendor Manager', 'vendor', '00000000-0000-0000-0000-000000000003', TRUE, NOW(), NOW()),
  ('00000000-0000-0000-0000-000000000002', 'candidate@videoplatform.com', '$2a$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', 'John Candidate', 'candidate', '00000000-0000-0000-0000-000000000003', TRUE, NOW(), NOW());

-- Seed Default QC Configs
INSERT INTO admin_qc_configs (key, value, description) VALUES
  ('auto_assignment_enabled',   'true', 'Auto-assign tickets on upload'),
  ('auto_reassignment_enabled', 'true', 'Auto-reassign on reviewer inactivity'),
  ('inactivity_timeout_hours',  '24',   'Hours before reassignment'),
  ('max_tickets_per_reviewer',  '50',   'Max concurrent tickets per reviewer'),
  ('assignment_strategy',       'LEAST_WORKLOAD', 'Distribution algorithm');
`;

async function resetDatabase() {
  const client = await pool.connect();
  try {
    console.log('🔌 Connected to Neon PostgreSQL Database');
    console.log('🧹 Wiping all old tables and recreating fresh production schema...\n');
    await client.query(resetScript);
    console.log('✅ SUCCESS! All 16 production tables created & fresh seed credentials inserted successfully!');
  } catch (err) {
    console.error('❌ Error resetting database:', err.message);
  } finally {
    client.release();
    pool.end();
  }
}

resetDatabase();
