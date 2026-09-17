/**
 * Real-Time Notification Service
 * Handles event de-duplication, SSE real-time push streaming, read-once state persistence,
 * and database queries. ZERO static/dummy notifications.
 */

const db = require('../database/connection');
const logger = require('../utils/logger');

// Connected SSE Stream Response Clients
const sseClients = new Set();

class NotificationService {
  /**
   * Create Real-Time System Notification with 10-Second De-Duplication Check
   */
  async createNotification({ user_id, role = 'candidate', title, message, video_id = null, task_id = null, type = 'system', color = '#10b981' }) {
    if (!title || !message) return null;

    try {
      // 1. De-Duplication Check: Verify if identical unread notification exists within last 10 seconds
      if (user_id && video_id) {
        const dedupeQuery = `
          SELECT id FROM notifications
          WHERE user_id = $1 AND event_type = $2 AND related_video_id = $3 AND is_read = FALSE
            AND created_at > NOW() - INTERVAL '10 seconds'
        `;
        const dupRes = await db.query(dedupeQuery, [user_id, type, video_id]).catch(() => ({ rowCount: 0 }));
        if (dupRes.rowCount > 0) {
          logger.info(`Ignored duplicate notification within 10s window for user ${user_id}, video ${video_id}`);
          return dupRes.rows[0];
        }
      }

      // 2. Insert Notification into Database (Unified Schema Insert)
      const insertQuery = `
        INSERT INTO notifications (
          user_id, user_role, role, title, message, event_type, type, related_video_id, is_read, created_at
        ) VALUES ($1, $2, $2, $3, $4, $5, $5, $6, FALSE, NOW())
        RETURNING *
      `;
      const res = await db.query(insertQuery, [user_id, role || 'candidate', title, message, type || 'system', video_id]);

      const notif = res.rows[0];
      const payload = {
        id: notif.id,
        user_id: notif.user_id,
        role: notif.user_role,
        title: notif.title,
        desc: notif.message,
        message: notif.message,
        event_type: notif.event_type,
        video_id: notif.related_video_id,
        time: 'Just now',
        color,
        type,
        read: false,
        createdAt: notif.created_at,
      };

      // 3. Broadcast Real-Time Stream Event to Connected SSE & Socket.io Clients
      this.broadcastToClients(payload);

      return notif;
    } catch (err) {
      logger.error('Error creating real-time notification', { error: err.message });
      return null;
    }
  }

  /**
   * Register Socket.io Server instance
   */
  setSocketIO(io) {
    this.io = io;
  }

  /**
   * Broadcast real-time payload to active SSE stream clients and Socket.io clients
   */
  broadcastToClients(payload) {
    // 1. Socket.io push broadcast
    if (this.io) {
      try {
        this.io.emit('notification:new', payload);
        this.io.emit('notification', payload);
      } catch (e) {
        logger.warn('Socket.io emit error', { error: e.message });
      }
    }

    // 2. Targeted SSE push broadcast
    const dataStr = `data: ${JSON.stringify(payload)}\n\n`;
    for (const client of sseClients) {
      try {
        const clientRes = client.res || client;
        const cUserId = client.userId || null;
        const cRole = client.role || null;

        // Match target user ID or target role
        const matchesUser = payload.user_id && cUserId && String(cUserId) === String(payload.user_id);
        const matchesRole = payload.role && cRole && String(cRole).toLowerCase() === String(payload.role).toLowerCase();
        const isGlobalAdmin = cRole === 'admin';

        if (matchesUser || matchesRole || isGlobalAdmin || !payload.user_id) {
          clientRes.write(dataStr);
        }
      } catch (e) {
        sseClients.delete(client);
      }
    }
  }

  /**
   * Register SSE client for real-time notification push stream
   */
  registerSSEClient(res, userId = null, role = null) {
    const clientObj = { res, userId, role };
    sseClients.add(clientObj);
    res.on('close', () => {
      sseClients.delete(clientObj);
    });
  }

  /**
   * Get Unread & Real-Time Event Notifications for User
   */
  async getNotifications({ user_id, role }) {
    try {
      let queryText = `
        SELECT id, user_id, COALESCE(user_role, role) AS user_role, title, message, COALESCE(event_type, type, 'system') AS event_type, related_video_id, related_task_id, is_read, created_at
        FROM notifications
        WHERE is_read = FALSE
      `;
      const params = [];

      if (user_id) {
        params.push(user_id);
        queryText += ` AND (user_id = $${params.length} OR user_id IS NULL)`;
      }

      if (role) {
        params.push(role);
        queryText += ` AND (COALESCE(user_role, role) = $${params.length} OR COALESCE(user_role, role) = 'all')`;
      }

      queryText += ` ORDER BY created_at DESC LIMIT 50`;

      const res = await db.query(queryText, params);
      const notifications = res.rows.map((n) => {
        let color = '#10B981';
        if (n.event_type.includes('rejected')) color = '#EF4444';
        if (n.event_type.includes('qc_approved') || n.event_type.includes('sent_to_admin')) color = '#8B5CF6';
        if (n.event_type.includes('uploaded')) color = '#F59E0B';

        return {
          id: n.id,
          title: n.title,
          desc: n.message,
          message: n.message,
          event_type: n.event_type,
          video_id: n.related_video_id,
          task_id: n.related_task_id,
          time: n.created_at ? new Date(n.created_at).toISOString() : new Date().toISOString(),
          color,
          type: n.event_type,
          read: n.is_read,
          createdAt: n.created_at,
        };
      });

      const unreadCount = notifications.length;
      return { notifications, unreadCount };
    } catch (err) {
      return { notifications: [], unreadCount: 0 };
    }
  }

  /**
   * Mark Single Notification as Read (Read Once Behavior)
   */
  async markSingleRead(id) {
    if (!id) return false;
    try {
      await db.query(`UPDATE notifications SET is_read = TRUE, read_at = NOW() WHERE id = $1`, [id]);
      return true;
    } catch (err) {
      return false;
    }
  }

  /**
   * Mark All Notifications as Read for User
   */
  async markAllRead(user_id, role) {
    try {
      let queryText = `UPDATE notifications SET is_read = TRUE, read_at = NOW() WHERE is_read = FALSE`;
      const params = [];

      if (user_id) {
        params.push(user_id);
        queryText += ` AND user_id = $${params.length}`;
      }

      await db.query(queryText, params);
      return true;
    } catch (err) {
      return false;
    }
  }
}

module.exports = new NotificationService();
