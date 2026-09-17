/**
 * JWT Authentication Middleware
 * Protects private API endpoints by verifying the JWT Access Token in Authorization header.
 * Checks token revocation status before granting access.
 */

const jwt = require('jsonwebtoken');
const config = require('../config');
const TokenRevocation = require('../services/tokenRevocation.service');
const { SecurityLogger, SECURITY_EVENTS } = require('./securityLogger');

/**
 * Middleware to authenticate requests using JWT Access Tokens.
 * On valid JWT: sets req.user = decoded payload { id, email, role, name }
 * On missing/invalid/revoked token: returns 401
 */
const authenticateJWT = (req, res, next) => {
  const authHeader = req.headers.authorization || req.headers.Authorization;

  if (!authHeader || typeof authHeader !== 'string') {
    return res.status(401).json({
      status: 'error',
      message: 'Access denied. Authorization token required.',
    });
  }

  const parts = authHeader.trim().split(' ');
  if (parts.length !== 2 || parts[0] !== 'Bearer' || !parts[1]) {
    return res.status(401).json({
      status: 'error',
      message: 'Access denied. Malformed Bearer token format.',
    });
  }

  const token = parts[1];
  if (!token || token === 'undefined' || token === 'null') {
    return res.status(401).json({
      status: 'error',
      message: 'Access denied. Invalid session token.',
    });
  }

  // Check if token is revoked
  if (TokenRevocation.isRevoked(token)) {
    SecurityLogger.log(SECURITY_EVENTS.UNAUTHORIZED_ACCESS, {
      ip: req.ip,
      path: req.originalUrl,
      method: req.method,
      message: 'Attempted use of revoked token',
    });
    return res.status(401).json({
      status: 'error',
      message: 'Token has been revoked. Please login again.',
    });
  }

  try {
    const decoded = jwt.verify(token, config.jwt.secret);
    req.user = {
      id:          decoded.id          || decoded.sub || null,
      email:       decoded.email       || null,
      name:        decoded.name        || null,
      role:        decoded.role        || 'candidate',
      vendor_id:   decoded.vendor_id   || null,
      vendor_code: decoded.vendor_code || null,
      tokenId:     decoded.jti         || null,
    };
    return next();
  } catch (error) {
    if (error.name === 'TokenExpiredError') {
      return res.status(401).json({
        status: 'error',
        message: 'Token expired. Please refresh or login again.',
      });
    }
    return res.status(401).json({
      status: 'error',
      message: 'Authentication token invalid. Please login again.',
    });
  }
};

const optionalAuth = (req, res, next) => {
  const authHeader = req.headers.authorization || req.headers.Authorization;

  if (!authHeader || typeof authHeader !== 'string') {
    req.user = { id: null, role: 'guest', email: null };
    return next();
  }

  const parts = authHeader.trim().split(' ');
  if (parts.length !== 2 || parts[0] !== 'Bearer' || !parts[1]) {
    req.user = { id: null, role: 'guest', email: null };
    return next();
  }

  // Check revocation
  if (TokenRevocation.isRevoked(parts[1])) {
    req.user = { id: null, role: 'guest', email: null };
    return next();
  }

  try {
    const decoded = jwt.verify(parts[1], config.jwt.secret);
    req.user = {
      id:    decoded.id    || decoded.sub || null,
      email: decoded.email || null,
      name:  decoded.name  || null,
      role:  decoded.role  || 'candidate',
    };
  } catch (_) {
    req.user = { id: null, role: 'guest', email: null };
  }
  return next();
};

module.exports = {
  authenticateJWT,
  optionalAuth,
};
