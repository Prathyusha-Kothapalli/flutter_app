/**
 * Video Routes
 * Endpoints under /api/v1/videos
 * Now with auth on listing, role-based delete, and authenticated streaming.
 */

const express = require('express');
const router = express.Router();
const videoController = require('../controllers/video.controller');
const uploadVideoMiddleware = require('../middleware/upload.middleware');
const { authenticateJWT } = require('../middleware/auth.middleware');
const { requireRole } = require('../middleware/role.middleware');
const { uploadLimiter, dashboardLimiter } = require('../middleware/rateLimiter');
const { validateUploadedFile } = require('../middleware/fileSecurity');
const { SecurityLogger, SECURITY_EVENTS } = require('../middleware/securityLogger');
const {
  validateVideoIdParam,
  validateCreateVideo,
  validateUpdateVideo,
  validateUpdateVideoMetadata,
} = require('../validators/video.validator');

// POST /api/v1/videos/upload - Local MP4 Video File Upload
router.post('/upload',
  authenticateJWT,
  uploadLimiter,
  uploadVideoMiddleware,
  validateUploadedFile,
  (req, res, next) => {
    SecurityLogger.log(SECURITY_EVENTS.FILE_UPLOAD, {
      ip: req.ip,
      userId: req.user?.id,
      path: req.originalUrl,
      method: req.method,
      message: `File uploaded: ${req.file?.originalname}`,
      metadata: { filename: req.file?.filename, size: req.file?.size },
    });
    videoController.uploadVideo(req, res, next);
  }
);

// GET /api/v1/videos/candidate-stats - Live Database Candidate Dashboard Metrics
router.get('/candidate-stats', authenticateJWT, dashboardLimiter, (req, res, next) => videoController.getCandidateStats(req, res, next));

// GET /api/v1/videos - Get All Videos (FIX #8: requires authentication)
router.get('/', authenticateJWT, (req, res, next) => videoController.getAllVideos(req, res, next));

// POST /api/v1/videos/:id/signed-url - Generate signed URL for video access (FIX #7)
router.post('/:id/signed-url', authenticateJWT, validateVideoIdParam, (req, res, next) => videoController.getSignedUrl(req, res, next));

// GET /api/v1/videos/:id/stream - Authenticated video streaming (FIX #1: replaces static serving)
router.get('/:id/stream', authenticateJWT, validateVideoIdParam, (req, res, next) => videoController.streamVideo(req, res, next));

// Apply JWT authentication middleware to protect private video management endpoints
router.use(authenticateJWT);

// POST /api/v1/videos - Create Video Metadata
router.post('/', validateCreateVideo, (req, res, next) => videoController.createVideo(req, res, next));

// GET /api/v1/videos/:id - Get Video by ID
router.get('/:id', validateVideoIdParam, (req, res, next) => videoController.getVideoById(req, res, next));

// PUT /api/v1/videos/:id - Update Video Metadata
router.put('/:id', validateVideoIdParam, validateUpdateVideo, (req, res, next) => videoController.updateVideoMetadata(req, res, next));

// PATCH or PUT /api/v1/videos/:id/status - Update video status (Admin or QC Team)
router.patch('/:id/status', requireRole('admin', 'qc_team', 'qc', 'qc_reviewer'), validateVideoIdParam, (req, res, next) => videoController.updateVideoStatus(req, res, next));
router.put('/:id/status', requireRole('admin', 'qc_team', 'qc', 'qc_reviewer'), validateVideoIdParam, (req, res, next) => videoController.updateVideoStatus(req, res, next));

// DELETE /api/v1/videos/:id - Delete Video (FIX #9: requires admin, qc_team, qc, qc_reviewer, or vendor role)
router.delete('/:id', requireRole('admin', 'qc_team', 'qc', 'qc_reviewer', 'vendor'), validateVideoIdParam, (req, res, next) => videoController.deleteVideo(req, res, next));

module.exports = router;
