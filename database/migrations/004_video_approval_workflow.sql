-- ============================================================================
-- Video Review & Approval Workflow Migration
-- Migration: 004_video_approval_workflow.sql
-- Description: Adds workflow status constraints, review metadata columns,
--              and review history audit table.
-- ============================================================================

-- 1. Update videos table status CHECK constraint to support canonical workflow states
ALTER TABLE videos DROP CONSTRAINT IF EXISTS chk_videos_status;
ALTER TABLE videos
  ADD CONSTRAINT chk_videos_status CHECK (
    status IN (
      'QC_PENDING', 'QC_REJECTED', 'ADMIN_PENDING', 'ADMIN_REJECTED', 'FINAL_APPROVED',
      'pending', 'uploaded', 'under_review',
      'pending_qc', 'assigned_qc', 'in_review',
      'qc_approved', 'qc_rejected',
      'approved', 'rejected', 'deleted'
    )
  );

-- 2. Add review metadata tracking columns to videos table if not already present
ALTER TABLE videos ADD COLUMN IF NOT EXISTS qc_reviewer_id        UUID;
ALTER TABLE videos ADD COLUMN IF NOT EXISTS qc_reviewer_name      VARCHAR(200);
ALTER TABLE videos ADD COLUMN IF NOT EXISTS qc_decision           VARCHAR(50);
ALTER TABLE videos ADD COLUMN IF NOT EXISTS qc_rejection_reason   TEXT;
ALTER TABLE videos ADD COLUMN IF NOT EXISTS qc_reviewed_at        TIMESTAMPTZ;

ALTER TABLE videos ADD COLUMN IF NOT EXISTS admin_reviewer_id     UUID;
ALTER TABLE videos ADD COLUMN IF NOT EXISTS admin_reviewer_name   VARCHAR(200);
ALTER TABLE videos ADD COLUMN IF NOT EXISTS admin_decision        VARCHAR(50);
ALTER TABLE videos ADD COLUMN IF NOT EXISTS admin_rejection_reason TEXT;
ALTER TABLE videos ADD COLUMN IF NOT EXISTS admin_reviewed_at     TIMESTAMPTZ;

-- 3. Update qc_reviews table status CHECK constraint
ALTER TABLE qc_reviews DROP CONSTRAINT IF EXISTS chk_qc_reviews_status;
ALTER TABLE qc_reviews
  ADD CONSTRAINT chk_qc_reviews_status CHECK (
    status IN (
      'QC_PENDING', 'QC_APPROVED', 'QC_REJECTED',
      'ADMIN_PENDING', 'ADMIN_REJECTED', 'FINAL_APPROVED',
      'approved', 'rejected', 'qc_approved', 'qc_rejected'
    )
  );

-- 4. Create dedicated video_review_history table for immutable review auditing
CREATE TABLE IF NOT EXISTS video_review_history (
    id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    video_id          UUID NOT NULL,
    reviewer_id       UUID,
    reviewer_name     VARCHAR(200),
    reviewer_role     VARCHAR(50) NOT NULL, -- 'qc_team' | 'admin'
    action            VARCHAR(50) NOT NULL, -- 'QC_APPROVE', 'QC_REJECT', 'ADMIN_APPROVE', 'ADMIN_REJECT'
    from_status       VARCHAR(50),
    to_status         VARCHAR(50) NOT NULL,
    rejection_reason  TEXT,
    review_comments   TEXT,
    scores            JSONB,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_review_history_video_id ON video_review_history (video_id);
CREATE INDEX IF NOT EXISTS idx_review_history_reviewer ON video_review_history (reviewer_id);

-- Foreign key for video_review_history
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_review_history_video') THEN
    ALTER TABLE video_review_history
      ADD CONSTRAINT fk_review_history_video
      FOREIGN KEY (video_id) REFERENCES videos(id) ON DELETE CASCADE;
  END IF;
END $$;
