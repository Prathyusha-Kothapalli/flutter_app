/**
 * Vendor Service
 * Handles Vendor Creation, Database Persistence, Bcrypt Hashing,
 * Audit Trail Logging, Notifications, and Live Aggregations.
 */

const db = require('../database/connection');
const logger = require('../utils/logger');
const bcrypt = require('bcryptjs');
const notificationService = require('./notification.service');

async function generateNextVendorCode(companyName = '') {
  try {
    let prefix = 'VEN';
    if (companyName && companyName.trim()) {
      const clean = companyName.trim().toUpperCase().replace(/[^A-Z0-9]/g, '');
      if (clean.length >= 3) {
        prefix = clean.slice(0, 6);
      } else if (clean.length > 0) {
        prefix = clean;
      }
    }

    const res = await db.query(
      `SELECT vendor_code FROM vendors WHERE vendor_code LIKE $1 OR vendor_code LIKE 'VEN-%'`,
      [`${prefix}-%`]
    ).catch(() => ({ rows: [] }));

    let maxNum = 0;
    for (const row of res.rows) {
      if (row.vendor_code) {
        const match = row.vendor_code.match(/-(?:0*)(\d+)$/);
        if (match) {
          const num = parseInt(match[1], 10);
          if (num > maxNum) maxNum = num;
        }
      }
    }

    if (maxNum === 0) {
      const countRes = await db.query(`SELECT COUNT(*) FROM vendors WHERE deleted_at IS NULL`).catch(() => ({ rows: [{ count: 0 }] }));
      maxNum = parseInt(countRes.rows[0]?.count || 0, 10);
    }

    const nextNum = maxNum + 1;
    const padStr = nextNum < 10 ? `0${nextNum}` : `${nextNum}`;
    return `${prefix}-${padStr}`;
  } catch (_) {
    return `VEN-01`;
  }
}

class VendorService {
  /**
   * Create New Vendor with Password, Audit Logging, and Notifications
   */
  async createVendor({ company_name, contact_person, email, phone, password, address, created_by }) {
    try {
      const vendorCode = await generateNextVendorCode(company_name);
      const cleanEmail = (email || '').trim().toLowerCase();
      const cleanPassword = password && password.trim() ? password.trim() : 'vendor123';
      const passwordHash = await bcrypt.hash(cleanPassword, 10);

      // 1. Insert/Update Vendor Record into PostgreSQL vendors table
      const insertQuery = `
        INSERT INTO vendors (company_name, contact_person, email, phone, password_hash, vendor_code, is_active, created_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, TRUE, NOW(), NOW())
        ON CONFLICT (email) DO UPDATE SET
          password_hash = EXCLUDED.password_hash,
          company_name = EXCLUDED.company_name,
          contact_person = EXCLUDED.contact_person,
          phone = EXCLUDED.phone,
          vendor_code = EXCLUDED.vendor_code,
          is_active = TRUE,
          updated_at = NOW()
        RETURNING id, vendor_code, company_name, contact_person, email, phone, is_active, created_at, updated_at
      `;

      const res = await db.query(insertQuery, [
        company_name,
        contact_person || company_name,
        cleanEmail,
        phone || '+91 98765 00000',
        passwordHash,
        vendorCode,
      ]);

      const vendor = res.rows[0];

      // 2. Also store/sync vendor login details in users table
      await db.query(`
        INSERT INTO users (email, password_hash, full_name, role, vendor_id, is_active, created_at, updated_at)
        VALUES ($1, $2, $3, 'vendor', $4, TRUE, NOW(), NOW())
        ON CONFLICT (email) DO UPDATE SET
          password_hash = EXCLUDED.password_hash,
          full_name = EXCLUDED.full_name,
          vendor_id = EXCLUDED.vendor_id,
          is_active = TRUE,
          updated_at = NOW()
      `, [cleanEmail, passwordHash, company_name, vendor.id]).catch((err) => {
        logger.warn('Failed to sync vendor to users table', { error: err.message });
      });

      // 2. Insert Audit Log Entry in audit_logs table
      await db.query(`
        INSERT INTO audit_logs (action, actor_id, actor_role, resource_type, resource_id, details, created_at)
        VALUES ($1, $2, $3, $4, $5, $6, NOW())
      `, [
        'VENDOR_CREATED',
        created_by || 'admin-system',
        'admin',
        'vendor',
        vendor.id,
        JSON.stringify({ company_name, email, vendor_code: vendorCode }),
      ]).catch(() => {});

      // 3. Emit Real-Time Notification to Admin
      await notificationService.createNotification({
        user_id: null,
        role: 'admin',
        title: 'New Vendor Created 🎉',
        message: `Vendor "${company_name}" (${vendorCode}) has been created successfully.`,
        video_id: null,
        task_id: null,
        type: 'vendor_created',
        color: '#2563EB',
      }).catch(() => {});

      // 4. Return vendor
      return vendor;
    } catch (err) {
      logger.error('Error creating vendor in PostgreSQL:', { error: err.message });
      throw err;
    }
  }

  /**
   * Fetch All Active Vendors for Management List & Selection Dropdowns
   */
  async getAllVendors() {
    try {
      const res = await db.query(`
        SELECT v.id, v.vendor_code, v.company_name, v.contact_person, v.email, v.phone, v.is_active, v.created_at, v.updated_at,
               COALESCE(vc.candidate_count, 0) AS candidate_count,
               COALESCE(vv.video_count, 0) AS video_count
        FROM vendors v
        LEFT JOIN (
          SELECT vendor_id, COUNT(*) AS candidate_count FROM candidates WHERE deleted_at IS NULL GROUP BY vendor_id
        ) vc ON v.id = vc.vendor_id
        LEFT JOIN (
          SELECT vendor_id, COUNT(*) AS video_count FROM videos WHERE deleted_at IS NULL GROUP BY vendor_id
        ) vv ON v.id = vv.vendor_id
        WHERE v.deleted_at IS NULL
        ORDER BY v.created_at DESC
      `);

      return res.rows.map(r => ({
        id: r.id,
        vendor_code: r.vendor_code,
        name: r.company_name,
        contact: r.contact_person,
        email: r.email,
        phone: r.phone,
        candidates: parseInt(r.candidate_count, 10),
        videos: parseInt(r.video_count, 10),
        status: r.is_active ? 'Active' : 'Inactive',
        created_at: r.created_at,
      }));
    } catch (err) {
      logger.error('Error fetching all vendors', { error: err.message });
      return [];
    }
  }

  /**
   * Get Vendor by ID
   */
  async getVendorById(id) {
    try {
      const res = await db.query(`SELECT * FROM vendors WHERE id = $1 AND deleted_at IS NULL`, [id]);
      if (res.rowCount === 0) throw new Error('Vendor not found');
      return res.rows[0];
    } catch (err) {
      throw err;
    }
  }

  /**
   * Update Vendor
   */
  async updateVendor(id, { company_name, contact_person, email, phone, is_active }) {
    try {
      const res = await db.query(`
        UPDATE vendors
        SET company_name = COALESCE($1, company_name),
            contact_person = COALESCE($2, contact_person),
            email = COALESCE($3, email),
            phone = COALESCE($4, phone),
            is_active = COALESCE($5, is_active),
            updated_at = NOW()
        WHERE id = $6 AND deleted_at IS NULL
        RETURNING *
      `, [company_name, contact_person, email, phone, is_active, id]);
      if (res.rowCount === 0) throw new Error('Vendor not found');
      return res.rows[0];
    } catch (err) {
      throw err;
    }
  }

  /**
   * Soft Delete Vendor
   */
  async deleteVendor(id) {
    try {
      const res = await db.query(`UPDATE vendors SET deleted_at = NOW(), updated_at = NOW() WHERE id = $1 AND deleted_at IS NULL RETURNING id`, [id]);
      if (res.rowCount === 0) throw new Error('Vendor not found');
      return { message: 'Vendor soft-deleted successfully' };
    } catch (err) {
      throw err;
    }
  }

  /**
   * Fetch Live Database Statistics for Vendor Dashboard
   */
  async getVendorDashboardStats(vendorId = null) {
    try {
      let videoQueryText = `
        SELECT 
          COUNT(DISTINCT project_id) AS total_projects,
          COUNT(DISTINCT candidate_id) AS total_candidates,
          COUNT(*) AS total_uploaded,
          COUNT(CASE WHEN LOWER(status) = 'pending_qc' THEN 1 END) AS pending_qc,
          COUNT(CASE WHEN LOWER(status) = 'approved' THEN 1 END) AS approved_videos,
          COUNT(CASE WHEN LOWER(status) IN ('qc_rejected', 'rejected') THEN 1 END) AS rejected_videos
        FROM videos
        WHERE deleted_at IS NULL
      `;
      const params = [];
      if (vendorId) {
        params.push(vendorId);
        videoQueryText += ` AND vendor_id = $1`;
      }

      const res = await db.query(videoQueryText, params).catch(() => ({ rows: [{}] }));
      const v = res.rows[0] || {};

      return {
        total_projects: parseInt(v.total_projects || 0, 10),
        total_candidates: parseInt(v.total_candidates || 0, 10),
        total_uploaded: parseInt(v.total_uploaded || 0, 10),
        pending_qc: parseInt(v.pending_qc || 0, 10),
        approved_videos: parseInt(v.approved_videos || 0, 10),
        rejected_videos: parseInt(v.rejected_videos || 0, 10),
      };
    } catch (err) {
      return {
        total_projects: 0,
        total_candidates: 0,
        total_uploaded: 0,
        pending_qc: 0,
        approved_videos: 0,
        rejected_videos: 0,
      };
    }
  }
}

module.exports = new VendorService();
