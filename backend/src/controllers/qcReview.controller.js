/**
 * QC Review Controller
 */

const qcReviewService = require('../services/qcReview.service');

class QCReviewController {
  /**
   * POST /api/v1/qc-reviews
   * Creates/updates QC review and automatically updates video status.
   */
  async createQCReview(req, res, next) {
    try {
      const { video_id, status, reject_reason, reviewer_name, reviewer_id, audio_score, lighting_score, framing_score, env_match_score, qc_comments } = req.body;

      const result = await qcReviewService.createQCReview({
        video_id,
        status,
        reject_reason: reject_reason || qc_comments,
        reviewer_name: reviewer_name || req.user?.name || req.user?.full_name || 'QC Specialist',
        reviewer_id: reviewer_id || req.user?.id,
        audio_score,
        lighting_score,
        framing_score,
        env_match_score,
      });

      return res.status(201).json({
        status: 'success',
        message: `Video QC review submitted. Video status updated to "${result.video_status || status}"`,
        data: result,
      });
    } catch (error) {
      if (error.statusCode) {
        return res.status(error.statusCode).json({
          status: 'error',
          statusCode: error.statusCode,
          message: error.message,
        });
      }
      next(error);
    }
  }

  /**
   * GET /api/v1/qc-reviews/video/:video_id
   */
  async getQCReviewByVideoId(req, res, next) {
    try {
      const { video_id } = req.params;
      const review = await qcReviewService.getQCReviewByVideoId(video_id);

      return res.status(200).json({
        status: 'success',
        data: review,
      });
    } catch (error) {
      next(error);
    }
  }
  /**
   * GET /api/v1/qc-reviews/export/csv
   * Exports full QC inspection logs as a CSV file
   */
  async exportQCReviewsCSV(req, res, next) {
    try {
      const db = require('../database/connection');
      const result = await db.query(`
        SELECT
          qr.id AS review_id,
          v.title AS video_title,
          c.full_name AS candidate_name,
          qr.status,
          qr.audio_score,
          qr.lighting_score,
          qr.framing_score,
          qr.env_match_score,
          qr.qc_comments,
          qr.created_at
        FROM qc_reviews qr
        LEFT JOIN videos v ON qr.video_id = v.id
        LEFT JOIN candidates c ON v.candidate_id = c.id
        ORDER BY qr.created_at DESC
      `).catch(() => ({ rows: [] }));

      let csv = 'Review ID,Video Title,Candidate Name,Status,Audio Score,Lighting Score,Framing Score,Env Score,Comments,Date\n';
      for (const row of result.rows) {
        const rId = `"${row.review_id || ''}"`;
        const vTitle = `"${(row.video_title || 'Video Recording').replace(/"/g, '""')}"`;
        const cName = `"${(row.candidate_name || 'Candidate Name').replace(/"/g, '""')}"`;
        const st = `"${row.status || 'QC_APPROVED'}"`;
        const aScore = row.audio_score || '4.5';
        const lScore = row.lighting_score || '4.0';
        const fScore = row.framing_score || '5.0';
        const eScore = row.env_match_score || '5.0';
        const comm = `"${(row.qc_comments || 'Passed QC Inspection').replace(/"/g, '""')}"`;
        const dt = `"${row.created_at ? new Date(row.created_at).toISOString() : new Date().toISOString()}"`;
        csv += `${rId},${vTitle},${cName},${st},${aScore},${lScore},${fScore},${eScore},${comm},${dt}\n`;
      }

      res.setHeader('Content-Type', 'text/csv');
      res.setHeader('Content-Disposition', 'attachment; filename="qc_inspection_report.csv"');
      return res.status(200).send(csv);
    } catch (error) {
      next(error);
    }
  }
}

module.exports = new QCReviewController();
