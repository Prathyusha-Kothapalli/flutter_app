/**
 * Video Service
 * Business logic and database operations for Video entity.
 */

const db = require('../database/connection');
const path = require('path');
const logger = require('../utils/logger');
const qcTicketService = require('./qcTicket.service');
const notificationService = require('./notification.service');

class VideoService {
  async createVideo({ candidate_id, vendor_id, title, description, duration, environment_tag, latitude, longitude, device_id, recording_date, status = 'pending_qc' }) {
    try {
      const insertQuery = `
        INSERT INTO videos (candidate_id, vendor_id, title, description, duration, environment_tag, latitude, longitude, device_id, recording_date, status)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
        RETURNING *
      `;
      const result = await db.query(insertQuery, [
        candidate_id,
        vendor_id,
        title || 'New Video Recording',
        description || null,
        duration || 45,
        environment_tag || 'Kitchen',
        latitude || 17.3850,
        longitude || 78.4867,
        device_id || 'unknown',
        recording_date || new Date(),
        'pending_qc',
      ]);

      const video = result.rows[0];

      // Auto-create QC Ticket and trigger equal distribution
      await qcTicketService.createTicketForVideo(video).catch(() => {});

      // Issue real-time notification to Candidate
      await notificationService.createNotification({
        user_id: video.candidate_id,
        role: 'candidate',
        title: 'Video Uploaded & Pending QC',
        message: `Your video "${video.title}" has been uploaded and sent for Quality Check.`,
        video_id: video.id,
        type: 'video_uploaded',
        color: '#F59E0B',
      }).catch(() => {});

      // Issue notification to Vendor
      await notificationService.createNotification({
        user_id: video.vendor_id,
        role: 'vendor',
        title: 'New Video Uploaded by Candidate',
        message: `Candidate uploaded "${video.title}" in category ${video.environment_tag}.`,
        video_id: video.id,
        type: 'video_uploaded',
        color: '#0EA5E9',
      }).catch(() => {});

      return video;
    } catch (e) {
      logger.error('Error creating video', { error: e.message });
      throw e;
    }
  }

  async uploadVideo({ video_id, candidate_id, vendor_id, file, environment_tag, title }) {
    const relativePath = path.join('uploads', 'videos', file.filename || file.originalname).replace(/\\/g, '/');
    try {
      if (!candidate_id) {
        throw new Error('Candidate ID is required for video upload');
      }

      let validCandidateId = candidate_id;
      let validVendorId = null;

      // 1. Resolve candidate's id (UUID) and vendor_id (UUID)
      if (validCandidateId) {
        const candRes = await db.query(
          `SELECT c.id AS candidate_id, c.vendor_id
           FROM candidates c WHERE (c.id = $1 OR c.id::text = $1::text OR LOWER(c.email) = LOWER($1)) AND c.deleted_at IS NULL
           UNION
           SELECT u.id AS candidate_id, u.vendor_id
           FROM users u WHERE (u.id = $1 OR u.id::text = $1::text OR LOWER(u.email) = LOWER($1)) AND u.deleted_at IS NULL
           LIMIT 1`,
          [validCandidateId]
        ).catch(() => ({ rowCount: 0, rows: [] }));

        if (candRes.rowCount > 0) {
          if (candRes.rows[0].candidate_id) validCandidateId = candRes.rows[0].candidate_id;
          if (candRes.rows[0].vendor_id) validVendorId = candRes.rows[0].vendor_id;
        }
      }

      // 2. If vendor_id passed directly or not resolved yet, validate against vendors table
      if (vendor_id) {
        const checkPassedVen = await db.query(
          'SELECT id FROM vendors WHERE (id = $1 OR id::text = $1::text OR LOWER(vendor_code) = LOWER($1::text)) AND deleted_at IS NULL LIMIT 1',
          [vendor_id]
        ).catch(() => ({ rowCount: 0, rows: [] }));
        if (checkPassedVen.rowCount > 0) {
          validVendorId = checkPassedVen.rows[0].id;
        }
      }

      // 3. Fallback: If vendor_id still not resolved, assign first active vendor
      if (!validVendorId) {
        const anyVen = await db.query('SELECT id FROM vendors WHERE deleted_at IS NULL AND is_active = TRUE ORDER BY created_at ASC LIMIT 1').catch(() => ({ rowCount: 0, rows: [] }));
        if (anyVen.rowCount > 0) {
          validVendorId = anyVen.rows[0].id;
        }
      }

      let videoRecord;
      if (video_id && !video_id.startsWith('vid-')) {
        const updateQuery = `
          UPDATE videos SET file_name = $1, local_path = $2, file_size = $3, upload_date = NOW(), status = 'pending_qc', environment_tag = COALESCE($4, environment_tag), updated_at = NOW()
          WHERE id = $5 AND deleted_at IS NULL RETURNING *
        `;
        const result = await db.query(updateQuery, [file.originalname || file.filename, relativePath, file.size || 10485760, environment_tag, video_id]);
        videoRecord = result.rows[0];
      }

      if (!videoRecord) {
        const insertQuery = `
          INSERT INTO videos (candidate_id, vendor_id, title, file_name, local_path, file_size, environment_tag, upload_date, status, duration)
          VALUES ($1, $2, $3, $4, $5, $6, $7, NOW(), 'pending_qc', 15) RETURNING *
        `;
        const videoTitle = title || `${environment_tag || "Recorded"} Dataset Video`;
        const result = await db.query(insertQuery, [
          validCandidateId,
          validVendorId,
          videoTitle,
          file.originalname || file.filename,
          relativePath,
          file.size || 10485760,
          environment_tag || 'Kitchen',
        ]);
        videoRecord = result.rows[0];
      }

      // Auto-create QC Ticket and trigger equal reviewer distribution
      if (videoRecord) {
        await qcTicketService.createTicketForVideo(videoRecord).catch((err) => console.error('QC Ticket Error:', err.message));

        await notificationService.createNotification({
          user_id: videoRecord.candidate_id,
          role: 'candidate',
          title: 'Video Uploaded Successfully 🎉',
          message: `Your video "${videoRecord.title}" has been uploaded and sent for Quality Check.`,
          video_id: videoRecord.id,
          type: 'video_uploaded',
          color: '#F59E0B',
        }).catch(() => {});

        await notificationService.createNotification({
          user_id: null,
          role: 'admin',
          title: 'New Video Uploaded for QC Review 📹',
          message: `New video "${videoRecord.title}" (${videoRecord.environment_tag}) submitted for QC review.`,
          video_id: videoRecord.id,
          type: 'video_uploaded',
          color: '#2563EB',
        }).catch(() => {});

        if (videoRecord.vendor_id) {
          await notificationService.createNotification({
            user_id: videoRecord.vendor_id,
            role: 'vendor',
            title: 'New Candidate Video Uploaded 📹',
            message: `A candidate uploaded "${videoRecord.title}" in category ${videoRecord.environment_tag}.`,
            video_id: videoRecord.id,
            type: 'video_uploaded',
            color: '#0EA5E9',
          }).catch(() => {});
        }
      }

      return videoRecord;
    } catch (e) {
      console.error('Error uploading video to PostgreSQL:', e.message);
      throw e;
    }
  }

  async updateVideoMetadata(id, { duration, latitude, longitude, environment_tag, device_id, recording_date }) {
    try {
      const updateQuery = `
        UPDATE videos SET duration = $1, latitude = $2, longitude = $3, environment_tag = $4, device_id = $5, recording_date = $6, updated_at = NOW()
        WHERE id = $7 AND deleted_at IS NULL RETURNING *
      `;
      const result = await db.query(updateQuery, [duration, latitude, longitude, environment_tag, device_id, recording_date, id]);
      if (result.rowCount === 0) throw new Error('Video not found');
      return result.rows[0];
    } catch (e) {
      throw e;
    }
  }

  async getAllVideos({ candidate_id, vendor_id, vendor_code, status, page = 1, limit = 10 }) {
    const limitNum = Math.max(1, Math.min(100, parseInt(limit, 10) || 10));
    try {
      let countQuery = 'SELECT COUNT(*) FROM videos v LEFT JOIN candidates c ON v.candidate_id = c.id LEFT JOIN vendors ven ON v.vendor_id = ven.id WHERE v.deleted_at IS NULL';
      let selectQuery = `
        SELECT v.id, v.candidate_id, c.full_name AS candidate_name, v.vendor_id, ven.company_name AS vendor_name, ven.vendor_code,
               v.title, v.description, v.s3_url, v.file_name, v.local_path, v.file_size, v.duration,
               v.environment_tag, v.rejection_reason, v.latitude, v.longitude, v.device_id, v.recording_date, v.status,
               t.assigned_reviewer_id, t.assigned_reviewer_name,
               qr.audio_score, qr.lighting_score, qr.framing_score, qr.env_match_score, qr.qc_comments, qr.admin_comments,
               v.created_at, v.updated_at
        FROM videos v
        LEFT JOIN qc_tickets t ON v.id = t.video_id
        LEFT JOIN candidates c ON v.candidate_id = c.id
        LEFT JOIN vendors ven ON v.vendor_id = ven.id
        LEFT JOIN (
          SELECT DISTINCT ON (video_id) video_id, audio_score, lighting_score, framing_score, env_match_score, qc_comments, admin_comments
          FROM qc_reviews ORDER BY video_id, created_at DESC
        ) qr ON v.id = qr.video_id
        WHERE v.deleted_at IS NULL
      `;
      const params = [];
      if (candidate_id) {
        params.push(candidate_id);
        const candCond = ` AND (v.candidate_id::text = $${params.length}::text OR c.id::text = $${params.length}::text OR LOWER(c.email) = LOWER($${params.length}) OR v.candidate_id IN (SELECT id FROM candidates WHERE id::text = $${params.length}::text OR LOWER(email) = LOWER($${params.length}) UNION SELECT id FROM users WHERE id::text = $${params.length}::text OR LOWER(email) = LOWER($${params.length})))`;
        countQuery += candCond;
        selectQuery += candCond;
      }
      if (vendor_id || vendor_code) {
        if (vendor_id && vendor_code) {
          params.push(vendor_id, vendor_code);
          const venCond = ` AND (v.vendor_id = $${params.length - 1} OR c.vendor_id = $${params.length - 1} OR ven.id = $${params.length - 1} OR LOWER(ven.vendor_code) = LOWER($${params.length}))`;
          countQuery += venCond;
          selectQuery += venCond;
        } else if (vendor_id) {
          params.push(vendor_id);
          const venCond = ` AND (v.vendor_id = $${params.length} OR c.vendor_id = $${params.length} OR ven.id = $${params.length} OR LOWER(ven.vendor_code) = LOWER($${params.length}))`;
          countQuery += venCond;
          selectQuery += venCond;
        } else {
          params.push(vendor_code);
          const venCond = ` AND (LOWER(ven.vendor_code) = LOWER($${params.length}) OR v.vendor_id = $${params.length} OR c.vendor_id = $${params.length})`;
          countQuery += venCond;
          selectQuery += venCond;
        }
      }
      if (status) {
        params.push(status);
        countQuery += ` AND LOWER(v.status) = LOWER($${params.length})`;
        selectQuery += ` AND LOWER(v.status) = LOWER($${params.length})`;
      }

      const countResult = await db.query(countQuery, params);
      const total_records = parseInt(countResult.rows[0]?.count || 0, 10);
      const pageNum = Math.max(1, parseInt(page || 1, 10));
      const offsetNum = (pageNum - 1) * limitNum;
      selectQuery += ` ORDER BY v.created_at DESC LIMIT $${params.length + 1} OFFSET $${params.length + 2}`;
      const queryParams = [...params, limitNum, offsetNum];

      const result = await db.query(selectQuery, queryParams);
      const total_pages = Math.ceil(total_records / limitNum) || 1;
      return { items: result.rows, pagination: { total_records, page: pageNum, limit: limitNum, total_pages } };
    } catch (e) {
      return { items: [], pagination: { total_records: 0, page: 1, limit: limitNum, total_pages: 1 } };
    }
  }

  /**
   * Admin Final Approval / Rejection Update + Candidate & Vendor Real-Time Notifications
   */
  async updateVideoStatus(id, status, rejectionReason = '', actorId = null) {
    try {
      const normalizedStatus = status ? status.toString().toLowerCase() : 'approved';
      const isApproved = normalizedStatus.includes('approv');
      const finalStatus = isApproved ? 'approved' : 'rejected';

      const updateQuery = `
        UPDATE videos
        SET status = $1, rejection_reason = $2, updated_at = NOW()
        WHERE (id = $3 OR id::text = $3) AND deleted_at IS NULL
        RETURNING *
      `;
      const res = await db.query(updateQuery, [finalStatus, isApproved ? null : rejectionReason, id]);
      if (res.rowCount === 0) throw new Error('Video not found');

      const video = res.rows[0];

      // Update corresponding QC Ticket status if present
      const ticketStatus = isApproved ? 'qc_approved' : 'qc_rejected';
      await db.query(
        `UPDATE qc_tickets SET status = $1, updated_at = NOW() WHERE video_id = $2 OR video_id::text = $2`,
        [ticketStatus, video.id]
      ).catch(() => {});

      // Send Notification to Candidate
      if (video.candidate_id) {
        const notifTitle = isApproved ? 'Video Final Approved 🎉' : 'Video Review Update ⚠️';
        const notifMsg = isApproved
          ? `Your video "${video.title || 'Recording'}" has received final Admin approval!`
          : `Your video "${video.title || 'Recording'}" requires revision: ${rejectionReason || 'Admin criteria not met'}.`;

        await notificationService.createNotification({
          user_id: video.candidate_id,
          role: 'candidate',
          title: notifTitle,
          message: notifMsg,
          video_id: video.id,
          type: isApproved ? 'admin_approved' : 'admin_rejected',
          color: isApproved ? '#059669' : '#DC2626',
        }).catch(() => {});
      }

      // Send Notification to Vendor
      if (video.vendor_id) {
        await notificationService.createNotification({
          user_id: video.vendor_id,
          role: 'vendor',
          title: isApproved ? 'Candidate Video Approved 🏆' : 'Candidate Video Rejected ⚠️',
          message: `Video "${video.title || 'Recording'}" status updated to ${finalStatus}.`,
          video_id: video.id,
          type: 'vendor_video_update',
          color: isApproved ? '#059669' : '#DC2626',
        }).catch(() => {});
      }

      // Audit Log
      try {
        await db.query(
          `INSERT INTO audit_logs (actor_id, actor_role, action, resource_type, resource_id, details, created_at)
           VALUES ($1, $2, $3, $4, $5, $6, NOW())`,
          [
            actorId || '00000000-0000-0000-0000-000000000001',
            'admin',
            isApproved ? 'ADMIN_VIDEO_APPROVED' : 'ADMIN_VIDEO_REJECTED',
            'video',
            video.id,
            JSON.stringify({ status: finalStatus, rejectionReason }),
          ]
        );
      } catch (_) {}

      return video;
    } catch (e) {
      throw e;
    }
  }

  /**
   * Delete Video - soft delete DB record + physical file deletion
   */
  async deleteVideo(id) {
    // First, get the video to find the file path
    const videoRes = await db.query(`SELECT local_path FROM videos WHERE id = $1 AND deleted_at IS NULL`, [id]);
    if (videoRes.rows.length === 0) {
      throw new Error('Video not found');
    }

    const video = videoRes.rows[0];

    // Soft delete the database record
    const query = `UPDATE videos SET deleted_at = NOW(), status = 'deleted' WHERE id = $1 RETURNING id`;
    const res = await db.query(query, [id]);

    // FIX #2: Physically delete the file from disk
    if (video.local_path) {
      try {
        const fs = require('fs');
        const fullPath = require('path').resolve(__dirname, '../../', video.local_path);
        if (fs.existsSync(fullPath)) {
          fs.unlinkSync(fullPath);
          logger.info('Physical video file deleted', { videoId: id, path: video.local_path });
        }
      } catch (fileErr) {
        logger.warn('Failed to delete physical video file', { videoId: id, error: fileErr.message });
      }
    }

    return { message: 'Video deleted successfully', id };
  }

  /**
   * Fetch Live Database Statistics for Candidate Dashboard
   */
  async getCandidateDashboardStats(candidateId = null) {
    try {
      let queryText = `
        SELECT 
          COUNT(*) AS total_uploaded,
          COUNT(CASE WHEN LOWER(status) IN ('pending_qc', 'pending', 'assigned_qc', 'in_review', 'unassigned') THEN 1 END) AS pending_qc,
          COUNT(CASE WHEN LOWER(status) IN ('qc_approved', 'approved') THEN 1 END) AS qc_approved,
          COUNT(CASE WHEN LOWER(status) IN ('qc_rejected', 'rejected') THEN 1 END) AS qc_rejected,
          COUNT(CASE WHEN LOWER(status) IN ('qc_approved', 'approved') THEN 1 END) AS approved,
          COUNT(CASE WHEN LOWER(status) IN ('qc_rejected', 'rejected') THEN 1 END) AS rejected,
          COALESCE(SUM(duration), 0) AS total_duration_seconds,
          COALESCE(SUM(CASE WHEN LOWER(status) IN ('qc_approved', 'approved') THEN duration * 1.5 ELSE 0 END), 0) AS total_earnings
        FROM videos
        WHERE deleted_at IS NULL
      `;
      const params = [];
      if (candidateId) {
        params.push(candidateId);
        queryText += ` AND (
          candidate_id = $1
          OR candidate_id::text = $1::text
          OR candidate_id IN (
            SELECT id FROM candidates WHERE id = $1 OR id::text = $1::text OR LOWER(email) = LOWER($1::text)
            UNION
            SELECT id FROM users WHERE id = $1 OR id::text = $1::text OR LOWER(email) = LOWER($1::text)
          )
        )`;
      }

      const res = await db.query(queryText, params);
      const r = res.rows[0] || {};
      return {
        total_uploaded: parseInt(r.total_uploaded || 0, 10),
        pending_qc: parseInt(r.pending_qc || 0, 10),
        qc_approved: parseInt(r.qc_approved || 0, 10),
        qc_rejected: parseInt(r.qc_rejected || 0, 10),
        approved: parseInt(r.approved || 0, 10),
        rejected: parseInt(r.rejected || 0, 10),
        total_duration_seconds: parseInt(r.total_duration_seconds || 0, 10),
        total_earnings: parseFloat(r.total_earnings || 0),
      };
    } catch (err) {
      return {
        total_uploaded: 0,
        pending_qc: 0,
        qc_approved: 0,
        qc_rejected: 0,
        approved: 0,
        rejected: 0,
        total_earnings: 0,
      };
    }
  }
}

module.exports = new VideoService();
