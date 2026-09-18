/**
 * Admin Service
 * Handles Master Admin Controls, Live PostgreSQL Aggregations,
 * Admin Review Queue (ADMIN_PENDING videos ONLY),
 * Final Sign-Off (FINAL_APPROVED / ADMIN_REJECTED), and Real-Time Notifications.
 */

const db = require('../database/connection');
const logger = require('../utils/logger');
const videoService = require('./video.service');

class AdminService {
  /**
   * Fetch Live Database Statistics for Master Admin Dashboard
   */
  async getAdminDashboardStats() {
    try {
      const [candidatesRes, vendorsRes, qcMembersRes, videosRes] = await Promise.all([
        db.query(`SELECT COUNT(*) FROM candidates WHERE deleted_at IS NULL`).catch(() => ({ rows: [{ count: '0' }] })),
        db.query(`SELECT COUNT(*) FROM vendors WHERE deleted_at IS NULL`).catch(() => ({ rows: [{ count: '0' }] })),
        db.query(`SELECT COUNT(*) FROM reviewer_activity`).catch(() => ({ rows: [{ count: '0' }] })),
        db.query(`
          SELECT 
            COUNT(*) AS total_uploaded,
            COUNT(CASE WHEN UPPER(v.status) = 'QC_PENDING' OR LOWER(v.status) IN ('pending_qc', 'pending', 'assigned_qc', 'in_review', 'unassigned') THEN 1 END) AS pending_qc,
            COUNT(CASE WHEN UPPER(v.status) = 'ADMIN_PENDING' OR LOWER(v.status) = 'qc_approved' THEN 1 END) AS admin_pending,
            COUNT(CASE WHEN UPPER(v.status) = 'FINAL_APPROVED' OR LOWER(v.status) = 'approved' THEN 1 END) AS final_approved,
            COUNT(CASE WHEN UPPER(v.status) = 'QC_REJECTED' OR LOWER(v.status) = 'qc_rejected' THEN 1 END) AS qc_rejected,
            COUNT(CASE WHEN UPPER(v.status) = 'ADMIN_REJECTED' OR LOWER(v.status) = 'rejected' THEN 1 END) AS admin_rejected
          FROM videos v
          WHERE v.deleted_at IS NULL
        `).catch(() => ({ rows: [{ total_uploaded: '0', pending_qc: '0', admin_pending: '0', final_approved: '0', qc_rejected: '0', admin_rejected: '0' }] })),
      ]);

      const v = videosRes.rows[0] || {};
      const approvedCount = parseInt(v.final_approved || 0, 10);
      const totalUploaded = parseInt(v.total_uploaded || 0, 10);
      const totalRejected = parseInt(v.qc_rejected || 0, 10) + parseInt(v.admin_rejected || 0, 10);

      // Fetch real 7-day daily trends grouped by day from PostgreSQL
      let daily_trends = [];
      try {
        const trendsRes = await db.query(`
          SELECT
            TO_CHAR(DATE_TRUNC('day', COALESCE(upload_date, created_at)), 'Dy') AS day,
            COUNT(*) AS uploaded,
            COUNT(CASE WHEN UPPER(status) = 'FINAL_APPROVED' OR LOWER(status) = 'approved' THEN 1 END) AS approved,
            COUNT(CASE WHEN UPPER(status) LIKE '%REJECT%' OR LOWER(status) LIKE '%reject%' THEN 1 END) AS rejected
          FROM videos
          WHERE deleted_at IS NULL
            AND COALESCE(upload_date, created_at) >= NOW() - INTERVAL '7 days'
          GROUP BY DATE_TRUNC('day', COALESCE(upload_date, created_at))
          ORDER BY DATE_TRUNC('day', COALESCE(upload_date, created_at)) ASC
        `);
        daily_trends = trendsRes.rows.map(row => ({
          day: row.day,
          uploaded: parseInt(row.uploaded || 0, 10),
          approved: parseInt(row.approved || 0, 10),
          rejected: parseInt(row.rejected || 0, 10),
        }));
      } catch (trendErr) {
        logger.warn('daily_trends query failed, returning empty array', { error: trendErr.message });
        daily_trends = [];
      }

      let totalProjects = 0;
      try {
        const projRes = await db.query(`SELECT COUNT(DISTINCT environment_tag) AS cnt FROM videos WHERE deleted_at IS NULL`);
        totalProjects = parseInt(projRes.rows[0]?.cnt || 0, 10);
      } catch (_) {}

      return {
        total_candidates: parseInt(candidatesRes.rows[0]?.count || 0, 10),
        total_vendors: parseInt(vendorsRes.rows[0]?.count || 0, 10),
        total_qc_members: parseInt(qcMembersRes.rows[0]?.count || 0, 10),
        total_projects: totalProjects,
        total_uploaded_videos: totalUploaded,
        pending_qc: parseInt(v.pending_qc || 0, 10),
        qc_approved: parseInt(v.admin_pending || 0, 10),
        admin_pending: parseInt(v.admin_pending || 0, 10),
        qc_rejected: parseInt(v.qc_rejected || 0, 10),
        admin_rejected: parseInt(v.admin_rejected || 0, 10),
        approved: approvedCount,
        rejected: totalRejected,
        daily_trends,
      };
    } catch (err) {
      logger.error('Error fetching admin dashboard stats', { error: err.message });
      return {
        total_candidates: 0,
        total_vendors: 0,
        total_qc_members: 0,
        total_projects: 0,
        total_uploaded_videos: 0,
        pending_qc: 0,
        qc_approved: 0,
        admin_pending: 0,
        approved: 0,
        rejected: 0,
        daily_trends: [],
      };
    }
  }

  /**
   * Get Admin Review Queue: Strictly returns ONLY videos with status ADMIN_PENDING (or legacy qc_approved)
   */
  async getQCApprovedQueue() {
    try {
      const queryText = `
        SELECT v.id, v.title, v.description, v.duration, v.environment_tag, v.latitude, v.longitude,
               v.device_id, v.recording_date, v.status, v.upload_date, v.created_at, v.updated_at,
               c.id AS candidate_id, c.full_name AS candidate_name, c.email AS candidate_email, c.phone AS candidate_phone,
               ven.id AS vendor_id, ven.company_name AS vendor_name, ven.vendor_code,
               v.qc_reviewer_id, v.qc_reviewer_name, v.qc_decision, v.qc_rejection_reason, v.qc_reviewed_at,
               qr.reviewer_name AS qc_inspector_name, qr.audio_score, qr.lighting_score, qr.framing_score, qr.env_match_score, qr.qc_comments
        FROM videos v
        LEFT JOIN candidates c ON v.candidate_id = c.id
        LEFT JOIN vendors ven ON v.vendor_id = ven.id
        LEFT JOIN (
          SELECT DISTINCT ON (video_id) video_id, reviewer_name, audio_score, lighting_score, framing_score, env_match_score, qc_comments
          FROM qc_reviews ORDER BY video_id, created_at DESC
        ) qr ON v.id = qr.video_id
        WHERE v.deleted_at IS NULL
          AND (
            UPPER(v.status) = 'ADMIN_PENDING'
            OR LOWER(v.status) = 'admin_pending'
            OR LOWER(v.status) = 'qc_approved'
            OR LOWER(v.status) = 'pending_admin_review'
          )
        ORDER BY v.updated_at DESC
      `;
      const res = await db.query(queryText);
      return res.rows;
    } catch (err) {
      logger.warn('Fallback for getQCApprovedQueue:', { error: err.message });
      return [];
    }
  }

  /**
   * Admin Final Approval (ADMIN_PENDING → FINAL_APPROVED)
   */
  async approveVideo(videoId, adminComments = 'Approved by System Admin', adminId = null, adminName = 'System Administrator') {
    try {
      const updated = await videoService.updateVideoStatus(
        videoId,
        'FINAL_APPROVED',
        '',
        adminId || '00000000-0000-0000-0000-000000000001',
        'admin',
        adminName || 'System Administrator',
        { comments: adminComments }
      );
      return updated;
    } catch (err) {
      logger.error('Error in Admin approveVideo:', { error: err.message });
      throw err;
    }
  }

  /**
   * Admin Final Rejection (ADMIN_PENDING → ADMIN_REJECTED) with mandatory rejection reason
   */
  async rejectVideo(videoId, adminComments, adminId = null, adminName = 'System Administrator') {
    if (!adminComments || adminComments.trim().length === 0) {
      const error = new Error('Rejection reason is mandatory when Admin rejects a video.');
      error.statusCode = 400;
      throw error;
    }

    try {
      const updated = await videoService.updateVideoStatus(
        videoId,
        'ADMIN_REJECTED',
        adminComments.trim(),
        adminId || '00000000-0000-0000-0000-000000000001',
        'admin',
        adminName || 'System Administrator',
        { comments: adminComments }
      );
      return updated;
    } catch (err) {
      logger.error('Error in Admin rejectVideo:', { error: err.message });
      throw err;
    }
  }

  /**
   * Admin 1-Click Dispatch: Divides pending candidate videos evenly among active QC team members
   */
  async dispatchVideosToQC() {
    try {
      const pendingVideosRes = await db.query(`
        SELECT id, candidate_id, title FROM videos
        WHERE deleted_at IS NULL AND (UPPER(status) = 'QC_PENDING' OR LOWER(status) IN ('pending_qc', 'pending_dispatch', 'pending'))
        ORDER BY created_at ASC
      `);

      const videos = pendingVideosRes.rows;
      if (videos.length === 0) {
        return { dispatched_count: 0, message: 'No pending candidate videos to dispatch.' };
      }

      const qcMembersRes = await db.query(`
        SELECT id, full_name, email FROM users
        WHERE role IN ('qc', 'qc_team', 'qc_reviewer') AND is_active = TRUE
      `).catch(() => ({ rows: [] }));

      let qcMembers = qcMembersRes.rows;
      if (qcMembers.length === 0) {
        qcMembers = [{ id: 'a0000000-0000-0000-0000-000000000001', full_name: 'Lead QC Inspector' }];
      }

      let dispatchedCount = 0;
      for (let i = 0; i < videos.length; i++) {
        const video = videos[i];
        const assignedQC = qcMembers[i % qcMembers.length];
        const ticketCode = `TKT-${Math.floor(10000 + Math.random() * 90000)}`;

        await db.query(`
          INSERT INTO qc_tickets (ticket_code, video_id, candidate_id, vendor_id, assigned_reviewer_id, assigned_reviewer_name, status, created_at, updated_at)
          VALUES ($1, $2::uuid, NULLIF($3::text, '')::uuid, NULLIF($4::text, '')::uuid, NULLIF($5::text, '')::uuid, $6, 'assigned', NOW(), NOW())
          ON CONFLICT (video_id) DO UPDATE SET assigned_reviewer_id = EXCLUDED.assigned_reviewer_id, assigned_reviewer_name = EXCLUDED.assigned_reviewer_name, status = 'assigned', updated_at = NOW()
        `, [ticketCode, video.id, video.candidate_id || null, video.vendor_id || null, assignedQC.id, assignedQC.full_name || 'QC Specialist']).catch((err) => {
          logger.warn('Failed to insert qc_ticket in dispatchVideosToQC:', err.message);
        });

        await db.query(`UPDATE videos SET status = 'assigned_qc', updated_at = NOW() WHERE id::text = $1::text`, [video.id]).catch(() => {});

        dispatchedCount++;
      }

      logger.info(`Dispatched ${dispatchedCount} videos to ${qcMembers.length} QC members`);
      return {
        dispatched_count: dispatchedCount,
        qc_members_count: qcMembers.length,
        message: `Successfully divided and dispatched ${dispatchedCount} video(s) to ${qcMembers.length} QC reviewer(s).`,
      };
    } catch (err) {
      logger.error('Error in dispatchVideosToQC', { error: err.message });
      return { dispatched_count: 0, message: err.message };
    }
  }

  async createAdmin({ full_name, email, phone, password }) {
    const bcrypt = require('bcryptjs');
    const hash = await bcrypt.hash(password || 'admin123', 10);
    const query = `
      INSERT INTO admins (full_name, email, phone, password_hash)
      VALUES ($1, $2, $3, $4)
      RETURNING id, full_name, email, phone, created_at
    `;
    const res = await db.query(query, [full_name, email, phone || null, hash]);
    return res.rows[0];
  }

  async getAllAdmins({ page = 1, limit = 10 }) {
    const offset = (Math.max(1, parseInt(page)) - 1) * parseInt(limit);
    const query = `SELECT id, full_name, email, phone, created_at FROM admins LIMIT $1 OFFSET $2`;
    const countQuery = `SELECT COUNT(*) FROM admins`;
    const res = await db.query(query, [parseInt(limit), offset]);
    const countRes = await db.query(countQuery);
    return {
      items: res.rows,
      total: parseInt(countRes.rows[0].count),
      page: parseInt(page),
      limit: parseInt(limit),
    };
  }

  async getAdminById(id) {
    const query = `SELECT id, full_name, email, phone, created_at FROM admins WHERE id = $1`;
    const res = await db.query(query, [id]);
    if (res.rows.length === 0) throw new Error('Admin not found');
    return res.rows[0];
  }

  async updateAdmin(id, { full_name, phone, email, is_active }) {
    const query = `
      UPDATE admins
      SET full_name = COALESCE($2, full_name),
          phone = COALESCE($3, phone),
          email = COALESCE($4, email),
          is_active = COALESCE($5, is_active),
          updated_at = NOW()
      WHERE id = $1
      RETURNING id, full_name, email, phone, is_active, updated_at
    `;
    const res = await db.query(query, [id, full_name, phone, email, is_active]);
    if (res.rows.length === 0) throw new Error('Admin not found');
    return res.rows[0];
  }

  async createQCMember({ full_name, email, phone, password }) {
    const bcrypt = require('bcryptjs');
    const hash = await bcrypt.hash(password || 'qc123456', 10);
    const query = `
      INSERT INTO users (full_name, email, phone, password_hash, role, is_active, created_at, updated_at)
      VALUES ($1, $2, $3, $4, 'qc_team', TRUE, NOW(), NOW())
      ON CONFLICT (email) DO UPDATE SET full_name = EXCLUDED.full_name, password_hash = EXCLUDED.password_hash, role = 'qc_team', updated_at = NOW()
      RETURNING id, full_name, email, phone, role, created_at
    `;
    const res = await db.query(query, [full_name, email, phone || null, hash]);
    return res.rows[0];
  }

  async deleteAdmin(id) {
    const query = `UPDATE admins SET deleted_at = NOW(), is_active = FALSE WHERE id = $1 AND deleted_at IS NULL RETURNING id`;
    const res = await db.query(query, [id]);
    if (res.rows.length === 0) throw new Error('Admin not found');
    return { message: 'Admin deleted successfully' };
  }
}

module.exports = new AdminService();
