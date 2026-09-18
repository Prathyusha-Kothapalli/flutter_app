/**
 * QC Ticket Controller
 * REST API Handlers for Ticket Management, Auto-Reassignment, Activity Tracking, and Audit Logging
 */

const qcTicketService = require('../services/qcTicket.service');

class QCTicketController {
  async getDashboardStats(req, res, next) {
    try {
      const reviewerId = req.user?.id || req.query.reviewer_id || null;
      const stats = await qcTicketService.getQCDashboardStats(reviewerId);
      return res.status(200).json({
        status: 'success',
        data: stats,
      });
    } catch (err) {
      next(err);
    }
  }

  async createTicket(req, res, next) {
    try {
      const ticket = await qcTicketService.createTicketForVideo(req.body);
      return res.status(201).json({
        status: 'success',
        message: 'QC ticket created and assigned',
        data: ticket,
      });
    } catch (err) {
      next(err);
    }
  }

  async assignTicket(req, res, next) {
    try {
      const ticketId = req.params.id || req.body.ticket_id || req.body.video_id;
      const reviewerId = req.body.reviewer_id || req.body.reviewerId;
      const reviewerName = req.body.reviewer_name || req.body.reviewerName;

      const result = await qcTicketService.assignTicketToReviewer(ticketId, reviewerId, reviewerName);
      return res.status(200).json({
        status: 'success',
        message: 'QC Ticket assigned successfully',
        data: result,
      });
    } catch (err) {
      next(err);
    }
  }

  async getMyTickets(req, res, next) {
    try {
      // STRICT REVIEWER ID SCOPING:
      // For QC role, ALWAYS force reviewerId filter to authenticated JWT user ID (req.user.id)
      const isQcRole = req.user && (req.user.role === 'qc' || req.user.role === 'qc_team' || req.user.role === 'qc_reviewer');
      const reviewerId = isQcRole ? req.user.id : (req.user?.id || req.query.reviewer_id);
      const statusFilter = req.query.status || null;

      const result = await qcTicketService.getMyAssignedTickets(reviewerId, statusFilter);
      return res.status(200).json({
        status: 'success',
        data: result.tickets,
        statistics: result.statistics,
      });
    } catch (err) {
      next(err);
    }
  }

  async updateTicketStatus(req, res, next) {
    try {
      const { id } = req.params;
      const { status, rejection_reason, reject_reason, reason } = req.body;
      const rejReason = rejection_reason || reject_reason || reason || '';

      const reviewerId = req.user?.id;
      const result = await qcTicketService.updateTicketStatus(id, status, reviewerId, rejReason);
      await qcTicketService.updateReviewerActivity(reviewerId, 'review_submission');

      return res.status(200).json({
        status: 'success',
        message: `Ticket ${id} status updated to ${status}`,
        data: result,
      });
    } catch (err) {
      next(err);
    }
  }

  async recordActivity(req, res, next) {
    try {
      const reviewerId = req.user?.id || req.body.reviewer_id;
      const activityType = req.body.activity_type || 'dashboard_view';
      const reviewerName = req.user?.name || req.body.reviewer_name;
      const reviewerEmail = req.user?.email || req.body.reviewer_email;

      const result = await qcTicketService.updateReviewerActivity(reviewerId, activityType, reviewerName, reviewerEmail);
      return res.status(200).json({
        status: 'success',
        data: result,
      });
    } catch (err) {
      next(err);
    }
  }

  async triggerAutoReassignment(req, res, next) {
    try {
      const ticketIds = req.body.ticket_ids || req.body.ticketIds || [];
      const assigned = await qcTicketService.distributeTicketsEqually(ticketIds);
      return res.status(200).json({
        status: 'success',
        message: `Distributed ${assigned.length} tickets equally across active reviewers`,
        data: assigned,
      });
    } catch (err) {
      next(err);
    }
  }

  async getActiveReviewers(req, res, next) {
    try {
      const reviewers = await qcTicketService.getActiveQCReviewers();
      return res.status(200).json({
        status: 'success',
        data: reviewers,
      });
    } catch (err) {
      next(err);
    }
  }

  async getReviewerActivity(req, res, next) {
    try {
      const reviewers = await qcTicketService.getAllReviewersActivity();
      return res.status(200).json({
        status: 'success',
        data: reviewers,
      });
    } catch (err) {
      next(err);
    }
  }

  async getQCConfigs(req, res, next) {
    try {
      const configs = await qcTicketService.getAllQCConfigs();
      return res.status(200).json({
        status: 'success',
        data: configs,
      });
    } catch (err) {
      next(err);
    }
  }

  async updateQCConfigs(req, res, next) {
    try {
      const configs = await qcTicketService.updateQCConfigs(req.body);
      return res.status(200).json({
        status: 'success',
        message: 'QC System Configuration Updated',
        data: configs,
      });
    } catch (err) {
      next(err);
    }
  }
}

module.exports = new QCTicketController();
