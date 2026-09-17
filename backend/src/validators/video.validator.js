/**
 * Video Request Validator
 */

const { isValidUUID } = require('../utils/uuid');

const ALLOWED_STATUSES = [
  'QC_PENDING', 'QC_REJECTED', 'ADMIN_PENDING', 'ADMIN_REJECTED', 'FINAL_APPROVED',
  'pending', 'uploaded', 'under_review',
  'pending_qc', 'assigned_qc', 'in_review',
  'qc_approved', 'qc_rejected',
  'approved', 'rejected', 'deleted',
];

function validateVideoIdParam(req, res, next) {
  const { id } = req.params;
  if (!isValidUUID(id)) {
    return res.status(400).json({
      status: 'error',
      statusCode: 400,
      message: 'Invalid UUID format for video ID',
    });
  }
  next();
}

function validateCreateVideo(req, res, next) {
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
  } = req.body || {};

  const errors = [];

  if (!candidate_id || !isValidUUID(candidate_id)) {
    errors.push({
      field: 'candidate_id',
      message: 'A valid candidate_id UUID is required',
    });
  }

  if (!vendor_id || !isValidUUID(vendor_id)) {
    errors.push({
      field: 'vendor_id',
      message: 'A valid vendor_id UUID is required',
    });
  }

  if (title !== undefined && typeof title !== 'string') {
    errors.push({
      field: 'title',
      message: 'title must be a string',
    });
  }

  if (duration !== undefined && (!Number.isInteger(duration) || duration < 0)) {
    errors.push({
      field: 'duration',
      message: 'duration must be a non-negative integer (seconds)',
    });
  }

  if (latitude !== undefined && (typeof latitude !== 'number' || latitude < -90 || latitude > 90)) {
    errors.push({
      field: 'latitude',
      message: 'latitude must be a number between -90 and 90',
    });
  }

  if (longitude !== undefined && (typeof longitude !== 'number' || longitude < -180 || longitude > 180)) {
    errors.push({
      field: 'longitude',
      message: 'longitude must be a number between -180 and 180',
    });
  }

  if (status !== undefined && !ALLOWED_STATUSES.includes(status)) {
    errors.push({
      field: 'status',
      message: `status must be one of: ${ALLOWED_STATUSES.join(', ')}`,
    });
  }

  if (errors.length > 0) {
    return res.status(400).json({
      status: 'error',
      statusCode: 400,
      message: 'Validation Error',
      errors,
    });
  }

  req.body.candidate_id = candidate_id.trim();
  req.body.vendor_id = vendor_id.trim();
  if (title) req.body.title = title.trim();
  if (description) req.body.description = description.trim();
  if (environment_tag) req.body.environment_tag = environment_tag.trim();
  req.body.status = status || 'pending';

  next();
}

function validateUpdateVideo(req, res, next) {
  const {
    title,
    description,
    duration,
    environment_tag,
    latitude,
    longitude,
    status,
  } = req.body || {};

  const errors = [];

  if (title !== undefined && typeof title !== 'string') {
    errors.push({
      field: 'title',
      message: 'title must be a string',
    });
  }

  if (duration !== undefined && (!Number.isInteger(duration) || duration < 0)) {
    errors.push({
      field: 'duration',
      message: 'duration must be a non-negative integer',
    });
  }

  if (latitude !== undefined && (typeof latitude !== 'number' || latitude < -90 || latitude > 90)) {
    errors.push({
      field: 'latitude',
      message: 'latitude must be a number between -90 and 90',
    });
  }

  if (longitude !== undefined && (typeof longitude !== 'number' || longitude < -180 || longitude > 180)) {
    errors.push({
      field: 'longitude',
      message: 'longitude must be a number between -180 and 180',
    });
  }

  if (status !== undefined && !ALLOWED_STATUSES.includes(status)) {
    errors.push({
      field: 'status',
      message: `status must be one of: ${ALLOWED_STATUSES.join(', ')}`,
    });
  }

  if (errors.length > 0) {
    return res.status(400).json({
      status: 'error',
      statusCode: 400,
      message: 'Validation Error',
      errors,
    });
  }

  if (title) req.body.title = title.trim();
  if (description) req.body.description = description.trim();
  if (environment_tag) req.body.environment_tag = environment_tag.trim();

  next();
}

function validateUpdateVideoMetadata(req, res, next) {
  const {
    duration,
    latitude,
    longitude,
    environment_tag,
    device_id,
    recording_date,
  } = req.body || {};

  const errors = [];

  if (duration !== undefined && (!Number.isInteger(duration) || duration < 0)) {
    errors.push({
      field: 'duration',
      message: 'duration must be a non-negative integer (seconds)',
    });
  }

  if (latitude !== undefined && (typeof latitude !== 'number' || latitude < -90 || latitude > 90)) {
    errors.push({
      field: 'latitude',
      message: 'latitude must be a number between -90 and 90',
    });
  }

  if (longitude !== undefined && (typeof longitude !== 'number' || longitude < -180 || longitude > 180)) {
    errors.push({
      field: 'longitude',
      message: 'longitude must be a number between -180 and 180',
    });
  }

  if (environment_tag !== undefined && typeof environment_tag !== 'string') {
    errors.push({
      field: 'environment_tag',
      message: 'environment_tag must be a string',
    });
  }

  if (device_id !== undefined && typeof device_id !== 'string') {
    errors.push({
      field: 'device_id',
      message: 'device_id must be a string',
    });
  }

  if (recording_date !== undefined && isNaN(Date.parse(recording_date))) {
    errors.push({
      field: 'recording_date',
      message: 'recording_date must be a valid ISO date string',
    });
  }

  if (errors.length > 0) {
    return res.status(400).json({
      status: 'error',
      statusCode: 400,
      message: 'Validation Error',
      errors,
    });
  }

  if (environment_tag) req.body.environment_tag = environment_tag.trim();
  if (device_id) req.body.device_id = device_id.trim();

  next();
}

module.exports = {
  validateVideoIdParam,
  validateCreateVideo,
  validateUpdateVideo,
  validateUpdateVideoMetadata,
};
