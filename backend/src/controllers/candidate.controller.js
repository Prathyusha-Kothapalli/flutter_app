/**
 * Candidate Controller
 */

const candidateService = require('../services/candidate.service');

class CandidateController {
  /**
   * POST /api/v1/candidates
   */
  async createCandidate(req, res, next) {
    try {
      let { vendor_id, full_name, phone, email } = req.body;

      if (req.user && req.user.role === 'vendor') {
        vendor_id = req.user.vendor_id || req.user.id;
      }

      const newCandidate = await candidateService.createCandidate({
        vendor_id,
        full_name,
        phone,
        email,
      });

      return res.status(201).json({
        status: 'success',
        message: 'Candidate created successfully',
        data: newCandidate,
      });
    } catch (error) {
      next(error);
    }
  }

  /**
   * GET /api/v1/candidates
   */
  async getCandidates(req, res, next) {
    try {
      let { vendor_id, vendor_code, page, limit } = req.query;

      // STRICT JWT VENDOR IDENTIFICATION:
      // If caller is vendor role, FORCE vendor_id to authenticated user token
      if (req.user && req.user.role === 'vendor') {
        vendor_id = req.user.vendor_id || req.user.id;
        vendor_code = req.user.vendor_code || null;
      }

      const result = await candidateService.getCandidates({
        vendor_id,
        vendor_code,
        page,
        limit,
      });

      return res.status(200).json({
        status: 'success',
        data: result,
      });
    } catch (error) {
      next(error);
    }
  }

  /**
   * GET /api/v1/candidates/stats
   */
  async getCandidateStats(req, res, next) {
    try {
      const { vendor_id } = req.query;
      const stats = await candidateService.getCandidateStats({ vendor_id });

      return res.status(200).json({
        status: 'success',
        message: 'Candidate status counts fetched successfully',
        data: stats,
      });
    } catch (error) {
      next(error);
    }
  }
}

module.exports = new CandidateController();
