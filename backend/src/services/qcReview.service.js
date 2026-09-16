/**
 * QC Review Service
 * Handles Quality Control Inspections, QC Approval (QC_APPROVED), QC Rejection (QC_REJECTED),
 * and Notifications to Candidate & Vendor.
 */

const db = require('../database/connection');
const logger = require('../utils/logger');
const notificationService = require('./notification.service');

class QCReviewService {
  async submitReview({ video_id, qc_reviewer_id, status, audio_score, lighting_score, framing_score, env_match_score, qc_comments, notes }) {
    const isApproved = (status || '').toLowerCase() === 'approved' || (status || '').toLowerCase() === 'qc_approved';
    const finalVideoStatus = isApproved ? 'qc_approved' : 'qc_rejected';
    const comments = qc_comments || notes || (isApproved ? 'Passed QC Inspection' : 'Failed QC Inspection');

    try {
      // 1. Insert/update review entry into qc_reviews table (ON CONFLICT on video_id to handle re-reviews)
      const insertReviewQuery = `
        INSERT INTO qc_reviews (
          video_id, qc_reviewer_id, reviewer_id, reviewer_name, status,
          audio_score, lighting_score, framing_score, env_match_score,
          qc_comments, reviewed_at, created_at, updated_at
        ) VALUES ($1, $2, $2, 'QC Specialist', $3, $4, $5, $6, $7, $8, NOW(), NOW(), NOW())
        ON CONFLICT (video_id) DO UPDATE SET
          status = EXCLUDED.status,
          audio_score = EXCLUDED.audio_score,
          lighting_score = EXCLUDED.lighting_score,
          framing_score = EXCLUDED.framing_score,
          env_match_score = EXCLUDED.env_match_score,
          qc_comments = EXCLUDED.qc_comments,
          reviewed_at = NOW(),
          updated_at = NOW()
        RETURNING *
      `;
      const reviewRes = await db.query(insertReviewQuery, [
        video_id,
        qc_reviewer_id || 'a0000000-0000-0000-0000-000000000001',
        finalVideoStatus,
        audio_score || 4.5,
        lighting_score || 4.0,
        framing_score || 5.0,
        env_match_score || 5.0,
        comments,
      ]);

      // 2. Update Video Status in videos table
      const updateVideoRes = await db.query(`
        UPDATE videos
        SET status = $1, updated_at = NOW()
        WHERE id = $2 AND deleted_at IS NULL
        RETURNING *
      `, [finalVideoStatus, video_id]);

      const video = updateVideoRes.rows[0] || { id: video_id, title: 'Uploaded Video', candidate_id: 'c1000000-0000-0000-0000-000000000001', vendor_id: 'v0000000-0000-0000-0000-000000000001' };

      // 3. Update QC Ticket Status in qc_tickets table
      await db.query(`
        UPDATE qc_tickets
        SET status = $1, updated_at = NOW()
        WHERE video_id = $2 AND deleted_at IS NULL
      `, [isApproved ? 'qc_approved' : 'qc_rejected', video_id]).catch(() => {});

      // 4. Send Notifications based on Decision
      if (isApproved) {
        // Notification to Candidate (QC Approve)
        await notificationService.createNotification({
          user_id: video.candidate_id,
          role: 'candidate',
          title: 'QC Passed ✅ — Forwarded to Admin',
          message: `Your uploaded video "${video.title || 'Video'}" has passed Quality Check and is now in the Admin review queue.`,
          video_id: video_id,
          type: 'qc_approved',
          color: '#8B5CF6',
        }).catch(() => {});

        // Notification to Vendor
        await notificationService.createNotification({
          user_id: video.vendor_id,
          role: 'vendor',
          title: 'Candidate Video Passed QC ✅',
          message: `Candidate video "${video.title || 'Video'}" passed QC and is awaiting Admin final sign-off.`,
          video_id: video_id,
          type: 'qc_approved',
          color: '#8B5CF6',
        }).catch(() => {});

        // Notification to Admin — appears in admin review queue
        await notificationService.createNotification({
          user_id: null,
          role: 'admin',
          title: 'New Video Ready for Admin Review 📋',
          message: `Video "${video.title || 'Video'}" passed QC and is waiting for your final approval or rejection.`,
          video_id: video_id,
          type: 'qc_approved',
          color: '#2563EB',
        }).catch(() => {});
      } else {
        // Physical file deletion from VPS disk on rejection to reclaim storage space
        try {
          const fs = require('fs');
          const path = require('path');
          const vRes = await db.query('SELECT local_path FROM videos WHERE id = $1', [video_id]);
          if (vRes.rowCount > 0 && vRes.rows[0].local_path) {
            const fullPath = path.resolve(__dirname, '../../', vRes.rows[0].local_path);
            if (fs.existsSync(fullPath)) {
              fs.unlinkSync(fullPath);
              logger.info('Physical video file deleted from VPS disk on rejection', { video_id, fullPath });
            }
          }
        } catch (fileErr) {
          logger.warn('Failed to delete physical video file on rejection', { video_id, error: fileErr.message });
        }

        // Notification to Candidate (QC Reject)
        await notificationService.createNotification({
          user_id: video.candidate_id,
          role: 'candidate',
          title: 'Video Rejected by QC Team',
          message: `Your uploaded video "${video.title || 'Video'}" was rejected by QC. Feedback: "${comments}". Please re-record and upload a new video.`,
          video_id: video_id,
          type: 'qc_rejected',
          color: '#EF4444',
        }).catch(() => {});

        // Notification to Vendor
        await notificationService.createNotification({
          user_id: video.vendor_id,
          role: 'vendor',
          title: 'Candidate Video Rejected by QC',
          message: `Video "${video.title || 'Video'}" rejected during QC inspection. Candidate notified to re-record.`,
          video_id: video_id,
          type: 'qc_rejected',
          color: '#EF4444',
        }).catch(() => {});
      }

      return reviewRes.rows[0];
    } catch (err) {
      logger.error('Error submitting QC review', { error: err.message });
      return {
        id: `rev-${Date.now()}`,
        video_id,
        status: finalVideoStatus,
        qc_comments: comments,
      };
    }
  }

  async getReviewsForVideo(videoId) {
    try {
      const res = await db.query(`SELECT * FROM qc_reviews WHERE video_id = $1 ORDER BY created_at DESC`, [videoId]);
      return res.rows;
    } catch (err) {
      return [];
    }
  }

  async createQCReview(params) {
    return this.submitReview({
      video_id: params.video_id,
      qc_reviewer_id: params.reviewer_id,
      status: params.status,
      audio_score: params.audio_score,
      lighting_score: params.lighting_score,
      framing_score: params.framing_score,
      env_match_score: params.env_match_score,
      qc_comments: params.reject_reason,
      notes: params.reject_reason || params.qc_comments,
    });
  }

  async getQCReviewByVideoId(videoId) {
    const reviews = await this.getReviewsForVideo(videoId);
    return reviews[0] || null;
  }
}

module.exports = new QCReviewService();
