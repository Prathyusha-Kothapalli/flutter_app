/**
 * QC Ticket System Routes
 */

const express = require('express');
const router = express.Router();
const qcTicketController = require('../controllers/qcTicket.controller');
const { authenticateJWT } = require('../middleware/auth.middleware');
const { requireRole } = require('../middleware/role.middleware');

// Protect all QC Ticket Endpoints
router.use(authenticateJWT);

// Get QC Dashboard Live Database Stats (admin, qc_team, qc, qc_reviewer)
router.get('/dashboard-stats', requireRole('admin', 'qc_team', 'qc', 'qc_reviewer'), qcTicketController.getDashboardStats);

// Get active registered QC reviewers (admin, qc_team, qc, qc_reviewer)
router.get('/active-reviewers', requireRole('admin', 'qc_team', 'qc', 'qc_reviewer'), qcTicketController.getActiveReviewers);

// Create / Assign Ticket (admin only)
router.post('/tickets', requireRole('admin'), qcTicketController.createTicket);
router.post('/tickets/assign', requireRole('admin', 'qc_team', 'qc', 'qc_reviewer'), qcTicketController.assignTicket);
router.post('/tickets/:id/assign', requireRole('admin', 'qc_team', 'qc', 'qc_reviewer'), qcTicketController.assignTicket);

// Get My Assigned Tickets & Dashboard Stats (admin, qc_team, qc, qc_reviewer)
router.get('/tickets/my-tickets', requireRole('admin', 'qc_team', 'qc', 'qc_reviewer'), qcTicketController.getMyTickets);

// Update Ticket Status (admin, qc_team, qc, qc_reviewer)
router.patch('/tickets/:id/status', requireRole('admin', 'qc_team', 'qc', 'qc_reviewer'), qcTicketController.updateTicketStatus);

// Record Reviewer Activity Timestamp
router.post('/tickets/reviewer-activity', requireRole('admin', 'qc_team', 'qc', 'qc_reviewer'), qcTicketController.recordActivity);

// Manual or Admin Trigger for Auto-Reassignment / Equal Division (admin, qc_team, qc, qc_reviewer)
router.post('/auto-divide', requireRole('admin', 'qc_team', 'qc', 'qc_reviewer'), qcTicketController.triggerAutoReassignment);
router.post('/tickets/auto-divide', requireRole('admin', 'qc_team', 'qc', 'qc_reviewer'), qcTicketController.triggerAutoReassignment);
router.post('/tickets/auto-reassign', requireRole('admin', 'qc_team', 'qc', 'qc_reviewer'), qcTicketController.triggerAutoReassignment);

// Get / Update Admin System Configurations (admin only)
router.get('/admin/qc-config', requireRole('admin'), qcTicketController.getQCConfigs);
router.put('/admin/qc-config', requireRole('admin'), qcTicketController.updateQCConfigs);

module.exports = router;
