/**
 * Admin Routes
 * Endpoints under /api/v1/admins
 */

const express = require('express');
const router = express.Router();
const adminController = require('../controllers/admin.controller');
const { authenticateJWT } = require('../middleware/auth.middleware');
const { requireRole } = require('../middleware/role.middleware');
const { dashboardLimiter } = require('../middleware/rateLimiter');
const {
  validateIdParam,
  validateCreateAdmin,
  validateUpdateAdmin,
} = require('../validators/admin.validator');

// Require Authentication and Admin Role for Admin Routes
router.use(authenticateJWT);
router.use(requireRole('admin'));

// GET /api/v1/admins/dashboard-stats - Live Database Metrics
router.get('/dashboard-stats', dashboardLimiter, (req, res, next) => adminController.getDashboardStats(req, res, next));

// GET /api/v1/admins/qc-queue & /api/v1/admins/qc-approved - Get QC_APPROVED video queue for Admin sign-off
router.get('/qc-queue', (req, res, next) => adminController.getQCApprovedQueue(req, res, next));
router.get('/qc-approved', (req, res, next) => adminController.getQCApprovedQueue(req, res, next));

// POST /api/v1/admins/videos/dispatch-qc - Divide & Send Pending Videos to QC Team Members
router.post('/videos/dispatch-qc', (req, res, next) => adminController.dispatchVideosToQC(req, res, next));

// POST /api/v1/admins/videos/:videoId/approve - Admin Approve Video
router.post('/videos/:videoId/approve', (req, res, next) => adminController.approveVideo(req, res, next));

// POST /api/v1/admins/videos/:videoId/reject - Admin Reject Video
router.post('/videos/:videoId/reject', (req, res, next) => adminController.rejectVideo(req, res, next));

// POST /api/v1/admins/qc-members - Create QC Evaluator Member
router.post('/qc-members', (req, res, next) => adminController.createQCMember(req, res, next));

// POST /api/v1/admins - Create Admin
router.post('/', validateCreateAdmin, (req, res, next) => adminController.createAdmin(req, res, next));

// GET /api/v1/admins - Get All Admins (Paginated)
router.get('/', (req, res, next) => adminController.getAllAdmins(req, res, next));

// GET /api/v1/admins/:id - Get Admin by ID
router.get('/:id', validateIdParam, (req, res, next) => adminController.getAdminById(req, res, next));

// PUT /api/v1/admins/:id - Update Admin
router.put('/:id', validateIdParam, validateUpdateAdmin, (req, res, next) => adminController.updateAdmin(req, res, next));

// DELETE /api/v1/admins/:id - Soft Delete Admin
router.delete('/:id', validateIdParam, (req, res, next) => adminController.deleteAdmin(req, res, next));

module.exports = router;
