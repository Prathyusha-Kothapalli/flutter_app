/**
 * Video Controller
 * Now with ownership checks, phantom record rejection, audit trail, signed URLs,
 * EXIF stripping, and watermarking.
 */

const videoService = require('../services/video.service');
const { SecurityLogger, SECURITY_EVENTS } = require('../middleware/securityLogger');
const SignedUrlService = require('../services/signedUrl.service');
const VideoProcessor = require('../services/videoProcessor.service');
const logger = require('../utils/logger');

class VideoController {
  async getCandidateStats(req, res, next) {
    try {
      // STRICT JWT CANDIDATE IDENTIFICATION:
      // Always identify candidate from authenticated JWT token (req.user.id)
      const candidateId = (req.user && req.user.role === 'candidate') ? req.user.id : (req.user?.id || req.query.candidate_id || null);
      const stats = await videoService.getCandidateDashboardStats(candidateId);
      return res.status(200).json({
        status: 'success',
        data: stats,
      });
    } catch (error) {
      next(error);
    }
  }

  async createVideo(req, res, next) {
    try {
      const {
        candidate_id,
        vendor_id,
        title,
        description,
        duration,
        environment_tag,
        latitude,
        longitude,
        status,
      } = req.body;

      const newVideo = await videoService.createVideo({
        candidate_id: (req.user && req.user.role === 'candidate') ? req.user.id : candidate_id,
        vendor_id,
        title,
        description,
        duration,
        environment_tag,
        latitude,
        longitude,
        status,
      });

      return res.status(201).json({
        status: 'success',
        message: 'Video metadata created successfully',
        data: newVideo,
      });
    } catch (error) {
      next(error);
    }
  }

  /**
   * Upload video - REJECTS phantom records (no file = 400 error)
   * Now with EXIF stripping and watermarking.
   */
  async uploadVideo(req, res, next) {
    try {
      // STRICT JWT CANDIDATE IDENTIFICATION:
      // Always identify candidate from authenticated JWT token (req.user.id)
      const candidate_id = req.user?.id;
      if (!candidate_id) {
        return res.status(401).json({
          status: 'error',
          statusCode: 401,
          message: 'Authentication required. Missing candidate authentication token.',
        });
      }

      // Reject phantom records — require actual file attachment
      if (!req.file) {
        return res.status(400).json({
          status: 'error',
          statusCode: 400,
          message: 'No video file attached. A valid MP4 file is required for upload.',
        });
      }

      const vendor_id = req.user?.vendor_id || req.body?.vendor_id || null;
      const environment_tag = req.body?.environment_tag;
      const title = req.body?.title;
      const file = req.file;

      // Step 1: Save video metadata and relative file path linked to authenticated user
      const uploadedVideo = await videoService.uploadVideo({
        video_id: req.body?.video_id,
        candidate_id,
        vendor_id,
        environment_tag,
        title,
        file,
      });

      // Step 2: Post-upload security processing (EXIF stripping + watermark)
      if (VideoProcessor.isAvailable() && file.path) {
        const processResult = await VideoProcessor.processVideo(file.path, {
          vendorId: uploadedVideo.vendor_id || vendor_id,
          candidateId: uploadedVideo.candidate_id || candidate_id,
          videoId: uploadedVideo.id,
        }).catch((e) => ({ success: false, error: e.message }));

        if (!processResult.success) {
          logger.warn('Video post-processing skipped', { error: processResult.error });
        }
      }

      return res.status(200).json({
        status: 'success',
        message: 'Video uploaded successfully',
        data: uploadedVideo,
      });
    } catch (error) {
      next(error);
    }
  }

  async updateVideoMetadata(req, res, next) {
    try {
      const { id } = req.params;
      const { duration, latitude, longitude, environment_tag, device_id, recording_date } = req.body;

      const updated = await videoService.updateVideoMetadata(id, {
        duration,
        latitude,
        longitude,
        environment_tag,
        device_id,
        recording_date,
      });

      return res.status(200).json({
        status: 'success',
        message: 'Video metadata updated successfully',
        data: updated,
      });
    } catch (error) {
      next(error);
    }
  }

  async getAllVideos(req, res, next) {
    try {
      let { candidate_id, vendor_id, vendor_code, status, page, limit } = req.query;

      // STRICT JWT CANDIDATE / VENDOR IDENTIFICATION & ISOLATION:
      if (req.user && req.user.role === 'candidate') {
        candidate_id = req.user.id;
        vendor_id = null;
        vendor_code = null;
      } else if (req.user && req.user.role === 'vendor') {
        vendor_id = req.user.vendor_id || req.user.id;
        vendor_code = req.user.vendor_code || null;
      }

      const result = await videoService.getAllVideos({
        candidate_id,
        vendor_id,
        vendor_code,
        status,
        page,
        limit,
        userRole: req.user?.role,
        userId: req.user?.id,
      });

      return res.status(200).json({
        status: 'success',
        data: result.items,
        pagination: result.pagination,
      });
    } catch (error) {
      next(error);
    }
  }

  async getVideoById(req, res, next) {
    try {
      const { id } = req.params;
      const video = await videoService.getVideoById(id);

      if (!video) {
        return res.status(404).json({
          status: 'error',
          statusCode: 404,
          message: 'Video not found',
        });
      }

      // Security check: Candidate isolation
      if (req.user && req.user.role === 'candidate' && video.candidate_id !== req.user.id) {
        return res.status(403).json({
          status: 'error',
          statusCode: 403,
          message: 'Access denied. You cannot view another candidate\'s video.',
        });
      }

      // Security check: Vendor isolation
      if (req.user && req.user.role === 'vendor') {
        const loggedVendorId = req.user.vendor_id || req.user.id;
        if (video.vendor_id !== loggedVendorId) {
          return res.status(403).json({
            status: 'error',
            statusCode: 403,
            message: 'Access denied. You cannot view another vendor\'s candidate video.',
          });
        }
      }

      // FIX #10: Log video view access
      SecurityLogger.log(SECURITY_EVENTS.FILE_VIEW, {
        ip: req.ip,
        userId: req.user?.id,
        path: req.originalUrl,
        method: req.method,
        message: `Video viewed: ${id}`,
        metadata: { videoId: id },
      });

      return res.status(200).json({
        status: 'success',
        data: video,
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
   * Delete video - with ownership check and physical file deletion
   */
  async deleteVideo(req, res, next) {
    try {
      const { id } = req.params;

      // FIX #9: Check ownership — candidates can only delete their own videos
      const video = await videoService.getVideoById(id);
      if (!video) {
        return res.status(404).json({
          status: 'error',
          statusCode: 404,
          message: 'Video not found',
        });
      }

      const userRole = req.user?.role;
      const userId = req.user?.id;

      // Candidates can only delete their own videos
      if (userRole === 'candidate' && video.candidate_id !== userId) {
        return res.status(403).json({
          status: 'error',
          statusCode: 403,
          message: 'Access denied. You can only delete your own videos.',
        });
      }

      // Vendors can only delete videos from their candidates
      if (userRole === 'vendor') {
        const loggedVendorId = req.user?.vendor_id || userId;
        if (video.vendor_id !== loggedVendorId) {
          return res.status(403).json({
            status: 'error',
            statusCode: 403,
            message: 'Access denied. You can only delete videos from your candidates.',
          });
        }
      }

      const result = await videoService.deleteVideo(id);

      // FIX #10: Log video deletion
      SecurityLogger.log(SECURITY_EVENTS.FILE_DELETE, {
        ip: req.ip,
        userId: req.user?.id,
        path: req.originalUrl,
        method: req.method,
        message: `Video deleted: ${id} by ${userRole}`,
        metadata: { videoId: id, deletedBy: userId, role: userRole },
      });

      return res.status(200).json({
        status: 'success',
        message: result.message || 'Video deleted successfully',
      });
    } catch (error) {
      next(error);
    }
  }

  /**
   * PATCH /api/v1/videos/:id/status - Admin or QC update video status
   */
  async updateVideoStatus(req, res, next) {
    try {
      const { id } = req.params;
      const { status, rejection_reason, reject_reason, reason, comments } = req.body;
      const rejReason = rejection_reason || reject_reason || reason || comments || '';
      const actorId = req.user?.id;
      const actorRole = req.user?.role || 'admin';
      const actorName = req.user?.name || req.user?.full_name || 'Reviewer';

      const video = await videoService.updateVideoStatus(id, status, rejReason, actorId, actorRole, actorName, { comments });

      return res.status(200).json({
        status: 'success',
        message: `Video ${id} status updated to ${video.status}`,
        data: video,
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
   * Generate signed URL for video access
   */
  async getSignedUrl(req, res, next) {
    try {
      const { id } = req.params;
      const { action = 'stream' } = req.query;
      const userId = req.user?.id;

      const video = await videoService.getVideoById(id);
      if (!video) {
        return res.status(404).json({
          status: 'error',
          statusCode: 404,
          message: 'Video not found',
        });
      }

      const { token, expiresAt } = SignedUrlService.generate(id, userId, action);

      // FIX #7: Log signed URL generation
      SecurityLogger.log(SECURITY_EVENTS.FILE_VIEW, {
        ip: req.ip,
        userId,
        path: req.originalUrl,
        method: req.method,
        message: `Signed URL generated for video: ${id}`,
        metadata: { videoId: id, action, expiresAt },
      });

      return res.status(200).json({
        status: 'success',
        data: {
          signedUrl: `/api/v1/videos/${id}/stream?token=${encodeURIComponent(token)}`,
          expiresAt,
          action,
        },
      });
    } catch (error) {
      next(error);
    }
  }

  /**
   * Stream video with signed token verification - replaces static file serving
   */
  async streamVideo(req, res, next) {
    try {
      const { id } = req.params;
      const { token } = req.query;

      // Verify signed token (FIX #7)
      if (token) {
        const verification = SignedUrlService.verify(token, id, req.user?.id, 'stream');
        if (!verification.valid) {
          return res.status(403).json({
            status: 'error',
            statusCode: 403,
            message: verification.expired
              ? 'Signed URL has expired. Please request a new one.'
              : 'Invalid signed URL.',
          });
        }
      }

      const video = await videoService.getVideoById(id);

      if (!video || !video.local_path) {
        return res.status(404).json({
          status: 'error',
          statusCode: 404,
          message: 'Video file not found',
        });
      }

      const fs = require('fs');
      const filePath = require('path').resolve(__dirname, '../../', video.local_path);

      if (!fs.existsSync(filePath)) {
        return res.status(404).json({
          status: 'error',
          statusCode: 404,
          message: 'Video file missing from storage',
        });
      }

      // FIX #10: Log video download/stream
      SecurityLogger.log(SECURITY_EVENTS.FILE_DOWNLOAD, {
        ip: req.ip,
        userId: req.user?.id,
        path: req.originalUrl,
        method: req.method,
        message: `Video streamed: ${id}`,
        metadata: { videoId: id, fileName: video.file_name },
      });

      const stat = fs.statSync(filePath);
      const fileSize = stat.size;
      const range = req.headers.range;

      const videoExtension = require('path').extname(video.file_name || video.local_path).slice(1) || 'mp4';
      const contentType = `video/${videoExtension === 'mov' ? 'quicktime' : videoExtension}`;

      if (range) {
        const parts = range.replace(/bytes=/, '').split('-');
        const start = parseInt(parts[0], 10);
        const end = parts[1] ? parseInt(parts[1], 10) : fileSize - 1;
        const chunkSize = end - start + 1;

        const stream = fs.createReadStream(filePath, { start, end });
        res.writeHead(206, {
          'Content-Range': `bytes ${start}-${end}/${fileSize}`,
          'Accept-Ranges': 'bytes',
          'Content-Length': chunkSize,
          'Content-Type': contentType,
          'X-Content-Type-Options': 'nosniff',
          'Cache-Control': 'no-store, no-cache, must-revalidate',
        });
        stream.pipe(res);
      } else {
        res.writeHead(200, {
          'Content-Length': fileSize,
          'Content-Type': contentType,
          'Accept-Ranges': 'bytes',
          'X-Content-Type-Options': 'nosniff',
          'Cache-Control': 'no-store, no-cache, must-revalidate',
        });
        fs.createReadStream(filePath).pipe(res);
      }
    } catch (error) {
      next(error);
    }
  }
}

module.exports = new VideoController();
