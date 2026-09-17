/**
 * QC Review Service
 * Handles Quality Control Inspections:
 * - QC Approval (QC_PENDING → ADMIN_PENDING)
 * - QC Rejection (QC_PENDING → QC_REJECTED with mandatory rejection reason)
 * - Audit review history and real-time notifications to Candidate, Vendor, & Admin
 */

const db = require('../database/connection');
const logger = require('../utils/logger');
const videoService = require('./video.service');

class QCReviewService {
  async submitReview({
    video_id,
    qc_reviewer_id,
    reviewer_name = 'QC Specialist',
    status,
    audio_score = 4.5,
    lighting_score = 4.0,
    framing_score = 5.0,
    env_match_score = 5.0,
    qc_comments,
    reject_reason,
    notes,
  }) {
    if (!video_id) {
      const error = new Error('video_id is required for QC review submission');
      error.statusCode = 400;
      throw error;
    }

    const rawStatus = (status || '').toString().trim().toUpperCase();
    const isApproved = rawStatus === 'APPROVED' || rawStatus === 'QC_APPROVED' || rawStatus === 'ADMIN_PENDING';
    const targetStatus = isApproved ? 'ADMIN_PENDING' : 'QC_REJECTED';
    const rejectionReason = reject_reason || qc_comments || notes || '';

    // Validate mandatory rejection reason if rejecting
    if (!isApproved && (!rejectionReason || rejectionReason.trim().length === 0)) {
      const error = new Error('Rejection reason is mandatory when rejecting a video during QC review.');
      error.statusCode = 400;
      throw error;
    }

    const comments = rejectionReason || (isApproved ? 'Passed QC Inspection' : 'Failed QC Inspection');

    try {
      // 1. Update Video status and history through VideoService controlled state machine
      const updatedVideo = await videoService.updateVideoStatus(
        video_id,
        targetStatus,
        isApproved ? '' : rejectionReason,
        qc_reviewer_id || 'a0000000-0000-0000-0000-000000000001',
        'qc_team',
        reviewer_name || 'QC Specialist',
        {
          comments,
          scores: {
            audio_score: parseFloat(audio_score) || 4.5,
            lighting_score: parseFloat(lighting_score) || 4.0,
            framing_score: parseFloat(framing_score) || 5.0,
            env_match_score: parseFloat(env_match_score) || 5.0,
          },
        }
      );

      // 2. Insert or update qc_reviews record
      const insertReviewQuery = `
        INSERT INTO qc_reviews (
          video_id, reviewer_id, reviewer_name, status,
          audio_score, lighting_score, framing_score, env_match_score,
          qc_comments, reject_reason, reviewed_at, created_at, updated_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NOW(), NOW(), NOW())
        ON CONFLICT (video_id) DO UPDATE SET
          status = EXCLUDED.status,
          reviewer_id = EXCLUDED.reviewer_id,
          reviewer_name = EXCLUDED.reviewer_name,
          audio_score = EXCLUDED.audio_score,
          lighting_score = EXCLUDED.lighting_score,
          framing_score = EXCLUDED.framing_score,
          env_match_score = EXCLUDED.env_match_score,
          qc_comments = EXCLUDED.qc_comments,
          reject_reason = EXCLUDED.reject_reason,
          reviewed_at = NOW(),
          updated_at = NOW()
        RETURNING *
      `;

      const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
      const validReviewerId = (qc_reviewer_id && uuidRegex.test(qc_reviewer_id.toString()))
        ? qc_reviewer_id.toString()
        : '30000000-0000-4000-8000-000000000001';

      const reviewRes = await db.query(insertReviewQuery, [
        video_id,
        validReviewerId,
        reviewer_name || 'QC Specialist',
        targetStatus,
        parseFloat(audio_score) || 4.5,
        parseFloat(lighting_score) || 4.0,
        parseFloat(framing_score) || 5.0,
        parseFloat(env_match_score) || 5.0,
        comments,
        isApproved ? null : rejectionReason,
      ]);

      return {
        ...reviewRes.rows[0],
        video_status: updatedVideo.status,
      };
    } catch (err) {
      logger.error('Error submitting QC review:', { error: err.message });
      throw err;
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
      qc_reviewer_id: params.reviewer_id || params.qc_reviewer_id,
      reviewer_name: params.reviewer_name,
      status: params.status,
      audio_score: params.audio_score,
      lighting_score: params.lighting_score,
      framing_score: params.framing_score,
      env_match_score: params.env_match_score,
      qc_comments: params.reject_reason || params.qc_comments,
      reject_reason: params.reject_reason || params.qc_comments,
      notes: params.reject_reason || params.qc_comments,
    });
  }

  async getQCReviewByVideoId(videoId) {
    const reviews = await this.getReviewsForVideo(videoId);
    return reviews[0] || null;
  }
}

module.exports = new QCReviewService();
