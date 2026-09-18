/**
 * Auth Validator
 * Validates authentication payloads for login and token refresh
 */

const validateLogin = (req, res, next) => {
  const { email, password } = req.body || {};

  if (!email || typeof email !== 'string' || !email.trim()) {
    return res.status(400).json({
      status: 'error',
      message: 'Email address is required',
    });
  }

  const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  if (!emailRegex.test(email.trim())) {
    return res.status(400).json({
      status: 'error',
      message: 'Invalid email address format',
    });
  }

  if (!password || typeof password !== 'string' || !password.trim()) {
    return res.status(400).json({
      status: 'error',
      message: 'Password is required',
    });
  }

  if (password.trim().length < 3) {
    return res.status(400).json({
      status: 'error',
      message: 'Password must be at least 3 characters long',
    });
  }

  next();
};

const validateRefreshToken = (req, res, next) => {
  const { refreshToken } = req.body || {};

  if (!refreshToken || typeof refreshToken !== 'string' || !refreshToken.trim()) {
    return res.status(400).json({
      status: 'error',
      message: 'Refresh token is required',
    });
  }

  next();
};

module.exports = {
  validateLogin,
  validateRefreshToken,
};
