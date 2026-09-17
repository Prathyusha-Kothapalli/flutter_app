/**
 * Video Service
 * Business logic and database operations for Video entity with strict
 * Role-Based Access Control and Controlled Workflow State Machine.
 *
 * Workflow: Candidate Upload (QC_PENDING) -> QC Review (ADMIN_PENDING / QC_REJECTED) -> Admin Review (FINAL_APPROVED / ADMIN_REJECTED)
 */

const db = require('../database/connection');
const path = require('path');
const logger = require('../utils/logger');
const qcTicketService = require('./qcTicket.service');
const notificationService = require('./notification.service');

// Controlled Workflow Transitions
const WORKFLOW_STATES = {
  QC_PENDING: 'QC_PENDING',
  QC_REJECTED: 'QC_REJECTED',
  ADMIN_PENDING: 'ADMIN_PENDING',
  ADMIN_REJECTED: 'ADMIN_REJECTED',
  FINAL_APPROVED: 'FINAL_APPROVED',
};

class VideoService {
  /**
   * Helper to normalize raw status string into standard uppercase workflow state
   */
  normalizeStatus(rawStatus) {
    if (!rawStatus) return WORKFLOW_STATES.QC_PENDING;
    const s = rawStatus.toString().trim().toUpperCase().replace(/ /g, '_');
    if (s === 'PENDING' || s === 'UPLOADED' || s === 'UNDER_REVIEW' || s === 'PENDING_QC' || s === 'ASSIGNED_QC' || s === 'IN_REVIEW') {
      return WORKFLOW_STATES.QC_PENDING;
    }
    if (s === 'QC_APPROVED' || s === 'PENDING_ADMIN_REVIEW' || s === 'ADMIN_PENDING') {
      return WORKFLOW_STATES.ADMIN_PENDING;
    }
    if (s === 'QC_REJECTED') {
      return WORKFLOW_STATES.QC_REJECTED;
    }
    if (s === 'APPROVED' || s === 'FINAL_APPROVED') {
      return WORKFLOW_STATES.FINAL_APPROVED;
    }
    if (s === 'REJECTED' || s === 'ADMIN_REJECTED') {
      return WORKFLOW_STATES.ADMIN_REJECTED;
    }
    return s;
  }

  /**
   * Validate that the requested status transition is permitted by the state machine and role
   */
  validateStatusTransition(currentStatus, targetStatus, role) {
    const current = this.normalizeStatus(currentStatus);
    const target = this.normalizeStatus(targetStatus);
    const userRole = (role || '').toLowerCase();

    // 1. Role permission checks
    if (userRole === 'candidate') {
      const error = new Error('Candidates are not authorized to approve, reject, or modify video review status.');
      error.statusCode = 403;
      throw error;
    }

    if (userRole === 'vendor') {
      const error = new Error('Vendors are not authorized to approve, reject, or modify video review status.');
      error.statusCode = 403;
      throw error;
    }

    // 2. QC Team permission checks
    if (userRole === 'qc_team' || userRole === 'qc_reviewer' || userRole === 'qc') {
      if (target === WORKFLOW_STATES.FINAL_APPROVED || target === WORKFLOW_STATES.ADMIN_REJECTED) {
        const error = new Error('QC reviewers cannot perform final Admin approval or rejection.');
        error.statusCode = 403;
        throw error;
      }
      if (current !== WORKFLOW_STATES.QC_PENDING) {
        const error = new Error(`QC reviewers can only review videos in QC_PENDING status. Current status is ${current}.`);
        error.statusCode = 400;
        throw error;
      }
      if (target !== WORKFLOW_STATES.ADMIN_PENDING && target !== WORKFLOW_STATES.QC_REJECTED) {
        const error = new Error(`Invalid transition for QC review: ${current} → ${target}. Expected ADMIN_PENDING or QC_REJECTED.`);
        error.statusCode = 400;
        throw error;
      }
      return { current, target };
    }

    // 3. Admin permission checks & State Machine validation
    if (userRole === 'admin') {
      // From QC_PENDING, admin can either QC approve/reject or dispatch
      if (current === WORKFLOW_STATES.QC_PENDING) {
        if (target === WORKFLOW_STATES.FINAL_APPROVED) {
          const error = new Error('Invalid workflow transition: QC_PENDING cannot transition directly to FINAL_APPROVED. QC review must take place first.');
          error.statusCode = 400;
          throw error;
        }
        if (target !== WORKFLOW_STATES.ADMIN_PENDING && target !== WORKFLOW_STATES.QC_REJECTED) {
          const error = new Error(`Invalid transition from QC_PENDING: cannot transition to ${target}.`);
          error.statusCode = 400;
          throw error;
        }
        return { current, target };
      }

      // From ADMIN_PENDING, admin can approve to FINAL_APPROVED or reject to ADMIN_REJECTED
      if (current === WORKFLOW_STATES.ADMIN_PENDING) {
        if (target !== WORKFLOW_STATES.FINAL_APPROVED && target !== WORKFLOW_STATES.ADMIN_REJECTED) {
          const error = new Error(`Invalid transition from ADMIN_PENDING: ${current} → ${target}. Expected FINAL_APPROVED or ADMIN_REJECTED.`);
          error.statusCode = 400;
          throw error;
        }
        return { current, target };
      }

      // Terminal states cannot be approved/regressed
      if (current === WORKFLOW_STATES.QC_REJECTED) {
        const error = new Error('Invalid transition: QC_REJECTED videos cannot be directly approved.');
        error.statusCode = 400;
        throw error;
      }
      if (current === WORKFLOW_STATES.ADMIN_REJECTED) {
        const error = new Error('Invalid transition: ADMIN_REJECTED videos cannot be directly approved.');
        error.statusCode = 400;
        throw error;
      }
      if (current === WORKFLOW_STATES.FINAL_APPROVED) {
        const error = new Error('Invalid transition: FINAL_APPROVED videos cannot be reset to pending review.');
        error.statusCode = 400;
        throw error;
      }
    }

    return { current, target };
  }

  /**
   * Candidate Metadata Video Creation
   */
  async createVideo({ candidate_id, vendor_id, title, description, duration, environment_tag, latitude, longitude, device_id, recording_date }) {
    try {
      let validCandidateId = candidate_id;
      let validVendorId = vendor_id;

      // Resolve candidate and assigned vendor
      if (validCandidateId) {
        const candRes = await db.query(
          `SELECT c.id AS candidate_id, c.vendor_id
           FROM candidates c WHERE (c.id = $1 OR c.id::text = $1::text OR LOWER(c.email) = LOWER($1)) AND c.deleted_at IS NULL
           LIMIT 1`,
          [validCandidateId]
        ).catch(() => ({ rowCount: 0, rows: [] }));

        if (candRes.rowCount > 0) {
          validCandidateId = candRes.rows[0].candidate_id;
          if (!validVendorId) validVendorId = candRes.rows[0].vendor_id;
        }
      }

      // Fallback to active vendor if not set
      if (!validVendorId) {
        const anyVen = await db.query('SELECT id FROM vendors WHERE deleted_at IS NULL AND is_active = TRUE ORDER BY created_at ASC LIMIT 1').catch(() => ({ rowCount: 0, rows: [] }));
        if (anyVen.rowCount > 0) {
          validVendorId = anyVen.rows[0].id;
        }
      }

      const insertQuery = `
        INSERT INTO videos (candidate_id, vendor_id, title, description, duration, environment_tag, latitude, longitude, device_id, recording_date, status)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, 'QC_PENDING')
        RETURNING *
      `;
      const result = await db.query(insertQuery, [
        validCandidateId,
        validVendorId,
        title || 'New Video Recording',
        description || null,
        duration || 45,
        environment_tag || 'Kitchen',
        latitude || 17.3850,
        longitude || 78.4867,
        device_id || 'unknown',
        recording_date || new Date(),
      ]);

      const video = result.rows[0];

      // Auto-create QC Ticket
      await qcTicketService.createTicketForVideo(video).catch(() => {});

      // Real-time notifications
      await notificationService.createNotification({
        user_id: video.candidate_id,
        role: 'candidate',
        title: 'Video Uploaded & Pending QC 📹',
        message: `Your video "${video.title}" has been uploaded and sent for Quality Check.`,
        video_id: video.id,
        type: 'video_uploaded',
        color: '#F59E0B',
      }).catch(() => {});

      if (video.vendor_id) {
        await notificationService.createNotification({
          user_id: video.vendor_id,
          role: 'vendor',
          title: 'New Candidate Video Uploaded 📹',
          message: `Candidate uploaded "${video.title}" in category ${video.environment_tag}. Status: QC_PENDING.`,
          video_id: video.id,
          type: 'video_uploaded',
          color: '#0EA5E9',
        }).catch(() => {});
      }

      return video;
    } catch (e) {
      logger.error('Error creating video', { error: e.message });
      throw e;
    }
  }

  /**
   * Candidate Video File Upload
   */
  async uploadVideo({ video_id, candidate_id, vendor_id, file, environment_tag, title }) {
    const relativePath = path.join('uploads', 'videos', file.filename || file.originalname).replace(/\\/g, '/');
    try {
      if (!candidate_id) {
        const error = new Error('Candidate ID is required for video upload');
        error.statusCode = 401;
        throw error;
      }

      let validCandidateId = candidate_id;
      let validVendorId = null;

      // 1. Resolve candidate's assigned vendor
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

      // 2. Validate vendor_id if passed
      if (vendor_id) {
        const checkPassedVen = await db.query(
          'SELECT id FROM vendors WHERE (id = $1 OR id::text = $1::text OR LOWER(vendor_code) = LOWER($1::text)) AND deleted_at IS NULL LIMIT 1',
          [vendor_id]
        ).catch(() => ({ rowCount: 0, rows: [] }));
        if (checkPassedVen.rowCount > 0) {
          validVendorId = checkPassedVen.rows[0].id;
        }
      }

      // 3. Fallback to first active vendor if unassigned
      if (!validVendorId) {
        const anyVen = await db.query('SELECT id FROM vendors WHERE deleted_at IS NULL AND is_active = TRUE ORDER BY created_at ASC LIMIT 1').catch(() => ({ rowCount: 0, rows: [] }));
        if (anyVen.rowCount > 0) {
          validVendorId = anyVen.rows[0].id;
        }
      }

      let videoRecord;
      if (video_id && !video_id.startsWith('vid-') && !video_id.startsWith('WEB-')) {
        const updateQuery = `
          UPDATE videos SET file_name = $1, local_path = $2, file_size = $3, upload_date = NOW(), status = 'QC_PENDING', environment_tag = COALESCE($4, environment_tag), vendor_id = COALESCE($5, vendor_id), updated_at = NOW()
          WHERE id = $6 AND deleted_at IS NULL RETURNING *
        `;
        const result = await db.query(updateQuery, [file.originalname || file.filename, relativePath, file.size || 10485760, environment_tag, validVendorId, video_id]);
        videoRecord = result.rows[0];
      }

      if (!videoRecord) {
        const insertQuery = `
          INSERT INTO videos (candidate_id, vendor_id, title, file_name, local_path, file_size, environment_tag, upload_date, status, duration)
          VALUES ($1, $2, $3, $4, $5, $6, $7, NOW(), 'QC_PENDING', 15) RETURNING *
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

      // Auto-create QC Ticket and trigger notifications
      if (videoRecord) {
        await qcTicketService.createTicketForVideo(videoRecord).catch((err) => logger.warn('QC Ticket Error:', err.message));

        await notificationService.createNotification({
          user_id: videoRecord.candidate_id,
          role: 'candidate',
          title: 'Video Uploaded Successfully 🎉',
          message: `Your video "${videoRecord.title}" has been uploaded and sent for Quality Check (QC_PENDING).`,
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
            message: `A candidate uploaded "${videoRecord.title}" in category ${videoRecord.environment_tag}. Status: QC_PENDING.`,
            video_id: videoRecord.id,
            type: 'video_uploaded',
            color: '#0EA5E9',
          }).catch(() => {});
        }
      }

      return videoRecord;
    } catch (e) {
      logger.error('Error uploading video:', { error: e.message });
      throw e;
    }
  }

  async updateVideoMetadata(id, { duration, latitude, longitude, environment_tag, device_id, recording_date }) {
    const updateQuery = `
      UPDATE videos SET duration = $1, latitude = $2, longitude = $3, environment_tag = $4, device_id = $5, recording_date = $6, updated_at = NOW()
      WHERE id = $7 AND deleted_at IS NULL RETURNING *
    `;
    const result = await db.query(updateQuery, [duration, latitude, longitude, environment_tag, device_id, recording_date, id]);
    if (result.rowCount === 0) {
      const error = new Error('Video not found');
      error.statusCode = 404;
      throw error;
    }
    return result.rows[0];
  }

  /**
   * Get All Videos with Strict Server-Side Role and Vendor Scoping
   */
  async getAllVideos({ candidate_id, vendor_id, vendor_code, status, page = 1, limit = 10, userRole = null, userId = null }) {
    const limitNum = Math.max(1, Math.min(100, parseInt(limit, 10) || 10));
    try {
      let countQuery = `
        SELECT COUNT(*) FROM videos v
        LEFT JOIN candidates c ON v.candidate_id = c.id
        LEFT JOIN vendors ven ON v.vendor_id = ven.id
        WHERE v.deleted_at IS NULL
      `;
      let selectQuery = `
        SELECT v.id, v.candidate_id, c.full_name AS candidate_name, c.email AS candidate_email, c.phone AS candidate_phone,
               v.vendor_id, ven.company_name AS vendor_name, ven.vendor_code,
               v.title, v.description, v.s3_url, v.file_name, v.local_path, v.file_size, v.duration,
               v.environment_tag, v.rejection_reason, v.latitude, v.longitude, v.device_id, v.recording_date, v.status,
               v.qc_reviewer_id, v.qc_reviewer_name, v.qc_decision, v.qc_rejection_reason, v.qc_reviewed_at,
               v.admin_reviewer_id, v.admin_reviewer_name, v.admin_decision, v.admin_rejection_reason, v.admin_reviewed_at,
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

      // 1. Candidate Scoping: Candidate can strictly only see their own videos
      if (candidate_id) {
        params.push(candidate_id);
        const candCond = ` AND (
          v.candidate_id = $${params.length}
          OR v.candidate_id::text = $${params.length}::text
          OR c.id = $${params.length}
          OR c.id::text = $${params.length}::text
          OR LOWER(c.email) = LOWER($${params.length})
        )`;
        countQuery += candCond;
        selectQuery += candCond;
      }

      // 2. Vendor Scoping: Vendor can strictly only see their assigned candidates' videos
      if (vendor_id || vendor_code) {
        if (vendor_id && vendor_code) {
          params.push(vendor_id, vendor_code);
          const venCond = ` AND (v.vendor_id = $${params.length - 1} OR c.vendor_id = $${params.length - 1} OR ven.id = $${params.length - 1} OR LOWER(ven.vendor_code) = LOWER($${params.length}))`;
          countQuery += venCond;
          selectQuery += venCond;
        } else if (vendor_id) {
          params.push(vendor_id);
          const venCond = ` AND (v.vendor_id = $${params.length} OR c.vendor_id = $${params.length} OR ven.id = $${params.length} OR LOWER(ven.vendor_code) = LOWER($${params.length}::text))`;
          countQuery += venCond;
          selectQuery += venCond;
        } else {
          params.push(vendor_code);
          const venCond = ` AND (LOWER(ven.vendor_code) = LOWER($${params.length}) OR v.vendor_id = $${params.length} OR c.vendor_id = $${params.length})`;
          countQuery += venCond;
          selectQuery += venCond;
        }
      }

      // 3. Status Filter (with normalized synonyms)
      if (status) {
        const norm = this.normalizeStatus(status);
        params.push(norm);
        const statusCond = ` AND (
          UPPER(v.status) = $${params.length}
          OR LOWER(v.status) = LOWER($${params.length})
          ${norm === 'QC_PENDING' ? `OR LOWER(v.status) IN ('pending', 'uploaded', 'under_review', 'pending_qc', 'assigned_qc', 'in_review')` : ''}
          ${norm === 'ADMIN_PENDING' ? `OR LOWER(v.status) IN ('qc_approved', 'pending_admin_review', 'admin_pending')` : ''}
          ${norm === 'QC_REJECTED' ? `OR LOWER(v.status) IN ('qc_rejected')` : ''}
          ${norm === 'FINAL_APPROVED' ? `OR LOWER(v.status) IN ('approved', 'final_approved')` : ''}
          ${norm === 'ADMIN_REJECTED' ? `OR LOWER(v.status) IN ('rejected', 'admin_rejected')` : ''}
        )`;
        countQuery += statusCond;
        selectQuery += statusCond;
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
      logger.error('Error fetching all videos:', { error: e.message });
      return { items: [], pagination: { total_records: 0, page: 1, limit: limitNum, total_pages: 1 } };
    }
  }

  /**
   * Get Single Video by ID with full candidate, vendor, and review metadata
   */
  async getVideoById(id) {
    const query = `
      SELECT v.id, v.candidate_id, c.full_name AS candidate_name, c.email AS candidate_email, c.phone AS candidate_phone,
             v.vendor_id, ven.company_name AS vendor_name, ven.vendor_code,
             v.title, v.description, v.s3_url, v.file_name, v.local_path, v.file_size, v.duration,
             v.environment_tag, v.rejection_reason, v.latitude, v.longitude, v.device_id, v.recording_date, v.status,
             v.qc_reviewer_id, v.qc_reviewer_name, v.qc_decision, v.qc_rejection_reason, v.qc_reviewed_at,
             v.admin_reviewer_id, v.admin_reviewer_name, v.admin_decision, v.admin_rejection_reason, v.admin_reviewed_at,
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
      WHERE (v.id::text = $1::text) AND v.deleted_at IS NULL
    `;
    const res = await db.query(query, [id]);
    if (res.rowCount === 0) {
      const error = new Error('Video not found');
      error.statusCode = 404;
      throw error;
    }
    return res.rows[0];
  }

  /**
   * Controlled Workflow Status Update
   * Enforces transition state machine, mandatory rejection reasons, review history, and notifications.
   */
  async updateVideoStatus(id, targetStatus, rejectionReason = '', actorId = null, actorRole = 'admin', actorName = 'Reviewer', extraData = {}) {
    // 1. Fetch current video record
    const currentVideo = await this.getVideoById(id);
    const currentStatus = this.normalizeStatus(currentVideo.status);
    const validated = this.validateStatusTransition(currentStatus, targetStatus, actorRole);
    const finalStatus = validated.target;

    // 2. Validate mandatory rejection reason
    if ((finalStatus === WORKFLOW_STATES.QC_REJECTED || finalStatus === WORKFLOW_STATES.ADMIN_REJECTED) && (!rejectionReason || rejectionReason.trim().length === 0)) {
      const error = new Error(`Rejection reason is mandatory when setting video status to ${finalStatus}.`);
      error.statusCode = 400;
      throw error;
    }

    const cleanRejectionReason = rejectionReason ? rejectionReason.trim() : null;
    const isQcAction = finalStatus === WORKFLOW_STATES.ADMIN_PENDING || finalStatus === WORKFLOW_STATES.QC_REJECTED;
    const isAdminAction = finalStatus === WORKFLOW_STATES.FINAL_APPROVED || finalStatus === WORKFLOW_STATES.ADMIN_REJECTED;

    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    const validActorId = (actorId && uuidRegex.test(actorId.toString()))
      ? actorId.toString()
      : (isQcAction ? '30000000-0000-4000-8000-000000000001' : '00000000-0000-0000-0000-000000000001');

    // 3. Update videos table with reviewer metadata
    let updateQuery;
    let queryParams;

    if (isQcAction) {
      updateQuery = `
        UPDATE videos
        SET status = $1,
            rejection_reason = $2,
            qc_reviewer_id = $3,
            qc_reviewer_name = $4,
            qc_decision = $5,
            qc_rejection_reason = $2,
            qc_reviewed_at = NOW(),
            updated_at = NOW()
        WHERE (id::text = $6::text) AND deleted_at IS NULL
        RETURNING *
      `;
      queryParams = [
        finalStatus,
        cleanRejectionReason,
        validActorId,
        actorName || 'QC Specialist',
        finalStatus === WORKFLOW_STATES.ADMIN_PENDING ? 'QC_APPROVED' : 'QC_REJECTED',
        id,
      ];
    } else {
      updateQuery = `
        UPDATE videos
        SET status = $1,
            rejection_reason = $2,
            admin_reviewer_id = $3,
            admin_reviewer_name = $4,
            admin_decision = $5,
            admin_rejection_reason = $2,
            admin_reviewed_at = NOW(),
            updated_at = NOW()
        WHERE (id::text = $6::text) AND deleted_at IS NULL
        RETURNING *
      `;
      queryParams = [
        finalStatus,
        cleanRejectionReason,
        validActorId,
        actorName || 'System Administrator',
        finalStatus === WORKFLOW_STATES.FINAL_APPROVED ? 'FINAL_APPROVED' : 'ADMIN_REJECTED',
        id,
      ];
    }

    const res = await db.query(updateQuery, queryParams);
    const updatedVideo = res.rows[0];

    // 4. Update corresponding QC Ticket if present
    const ticketStatus = finalStatus === WORKFLOW_STATES.QC_REJECTED ? 'qc_rejected' : 'qc_approved';
    await db.query(
      `UPDATE qc_tickets SET status = $1, updated_at = NOW() WHERE video_id::text = $2::text`,
      [ticketStatus, updatedVideo.id]
    ).catch(() => {});

    // 5. Append immutable review audit log in video_review_history
    try {
      await db.query(`
        INSERT INTO video_review_history (
          video_id, reviewer_id, reviewer_name, reviewer_role, action, from_status, to_status, rejection_reason, review_comments, scores, created_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NOW())
      `, [
        updatedVideo.id,
        validActorId,
        actorName || (isQcAction ? 'QC Specialist' : 'System Administrator'),
        actorRole || (isQcAction ? 'qc_team' : 'admin'),
        finalStatus,
        currentStatus,
        finalStatus,
        cleanRejectionReason,
        extraData?.comments || extraData?.qc_comments || extraData?.admin_comments || null,
        extraData?.scores ? JSON.stringify(extraData.scores) : null,
      ]);
    } catch (histErr) {
      logger.warn('Failed to insert into video_review_history:', { error: histErr.message });
    }

    // 6. Send Real-Time Notifications
    const isApproved = finalStatus === WORKFLOW_STATES.FINAL_APPROVED || finalStatus === WORKFLOW_STATES.ADMIN_PENDING;

    // Notification to Candidate
    if (updatedVideo.candidate_id) {
      let notifTitle = 'Video Status Update';
      let notifMsg = `Your video status is now ${finalStatus}.`;
      let notifColor = '#2563EB';

      if (finalStatus === WORKFLOW_STATES.ADMIN_PENDING) {
        notifTitle = 'QC Passed ✅ — Forwarded to Admin';
        notifMsg = `Your video "${updatedVideo.title}" passed Quality Check and is now waiting for Admin final review.`;
        notifColor = '#8B5CF6';
      } else if (finalStatus === WORKFLOW_STATES.QC_REJECTED) {
        notifTitle = 'QC Rejected ❌';
        notifMsg = `Your video "${updatedVideo.title}" was rejected during Quality Check. Reason: ${cleanRejectionReason}`;
        notifColor = '#DC2626';
      } else if (finalStatus === WORKFLOW_STATES.FINAL_APPROVED) {
        notifTitle = 'Final Approved 🎉';
        notifMsg = `Congratulations! Your video "${updatedVideo.title}" has received Final Admin Approval.`;
        notifColor = '#059669';
      } else if (finalStatus === WORKFLOW_STATES.ADMIN_REJECTED) {
        notifTitle = 'Admin Rejected ❌';
        notifMsg = `Your video "${updatedVideo.title}" was rejected by Admin. Reason: ${cleanRejectionReason}`;
        notifColor = '#DC2626';
      }

      await notificationService.createNotification({
        user_id: updatedVideo.candidate_id,
        role: 'candidate',
        title: notifTitle,
        message: notifMsg,
        video_id: updatedVideo.id,
        type: finalStatus.toLowerCase(),
        color: notifColor,
      }).catch(() => {});
    }

    // Notification to Vendor
    if (updatedVideo.vendor_id) {
      await notificationService.createNotification({
        user_id: updatedVideo.vendor_id,
        role: 'vendor',
        title: `Candidate Video Status: ${finalStatus}`,
        message: `Video "${updatedVideo.title}" status updated to ${finalStatus}.${cleanRejectionReason ? ` Reason: ${cleanRejectionReason}` : ''}`,
        video_id: updatedVideo.id,
        type: 'vendor_video_update',
        color: isApproved ? '#059669' : '#DC2626',
      }).catch(() => {});
    }

    // Audit log
    try {
      await db.query(
        `INSERT INTO audit_logs (actor_id, actor_role, action, resource_type, resource_id, details, created_at)
         VALUES ($1, $2, $3, $4, $5, $6, NOW())`,
        [
          actorId || '00000000-0000-0000-0000-000000000001',
          actorRole || 'admin',
          `VIDEO_STATUS_${finalStatus}`,
          'video',
          updatedVideo.id,
          JSON.stringify({ from: currentStatus, to: finalStatus, rejectionReason: cleanRejectionReason }),
        ]
      );
    } catch (_) {}

    return updatedVideo;
  }

  /**
   * Delete Video - soft delete DB record + physical file deletion
   */
  async deleteVideo(id) {
    const videoRes = await db.query(`SELECT local_path FROM videos WHERE id = $1 AND deleted_at IS NULL`, [id]);
    if (videoRes.rows.length === 0) {
      const error = new Error('Video not found');
      error.statusCode = 404;
      throw error;
    }

    const video = videoRes.rows[0];
    const query = `UPDATE videos SET deleted_at = NOW(), status = 'deleted' WHERE id = $1 RETURNING id`;
    const res = await db.query(query, [id]);

    if (video.local_path) {
      try {
        const fs = require('fs');
        const fullPath = path.resolve(__dirname, '../../', video.local_path);
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
          COUNT(CASE WHEN UPPER(status) = 'QC_PENDING' OR LOWER(status) IN ('pending_qc', 'pending', 'assigned_qc', 'in_review', 'unassigned') THEN 1 END) AS pending_qc,
          COUNT(CASE WHEN UPPER(status) = 'ADMIN_PENDING' OR LOWER(status) = 'qc_approved' THEN 1 END) AS admin_pending,
          COUNT(CASE WHEN UPPER(status) = 'QC_REJECTED' OR LOWER(status) = 'qc_rejected' THEN 1 END) AS qc_rejected,
          COUNT(CASE WHEN UPPER(status) = 'FINAL_APPROVED' OR LOWER(status) = 'approved' THEN 1 END) AS final_approved,
          COUNT(CASE WHEN UPPER(status) = 'ADMIN_REJECTED' OR LOWER(status) = 'rejected' THEN 1 END) AS admin_rejected,
          COALESCE(SUM(duration), 0) AS total_duration_seconds,
          COALESCE(SUM(CASE WHEN UPPER(status) = 'FINAL_APPROVED' OR LOWER(status) = 'approved' THEN duration * 1.5 ELSE 0 END), 0) AS total_earnings
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
        admin_pending: parseInt(r.admin_pending || 0, 10),
        qc_rejected: parseInt(r.qc_rejected || 0, 10),
        final_approved: parseInt(r.final_approved || 0, 10),
        admin_rejected: parseInt(r.admin_rejected || 0, 10),
        approved: parseInt(r.final_approved || 0, 10),
        rejected: parseInt(r.qc_rejected || 0, 10) + parseInt(r.admin_rejected || 0, 10),
        total_duration_seconds: parseInt(r.total_duration_seconds || 0, 10),
        total_earnings: parseFloat(r.total_earnings || 0),
      };
    } catch (err) {
      return {
        total_uploaded: 0,
        pending_qc: 0,
        admin_pending: 0,
        qc_rejected: 0,
        final_approved: 0,
        admin_rejected: 0,
        approved: 0,
        rejected: 0,
        total_duration_seconds: 0,
        total_earnings: 0,
      };
    }
  }
}

module.exports = new VideoService();
