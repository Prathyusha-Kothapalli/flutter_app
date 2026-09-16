const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '../../.env') });

const jwtSecret = process.env.JWT_SECRET || 'super_secret_jwt_access_token_key_2026_video_platform';
const jwtRefreshSecret = process.env.JWT_REFRESH_SECRET || 'super_secret_jwt_refresh_token_key_2026_video_platform';
const databaseUrl = process.env.DATABASE_URL || 'postgresql://postgres:postgrespassword@localhost:5432/videoplatform';

module.exports = {
  port: parseInt(process.env.PORT, 10) || 5000,
  nodeEnv: process.env.NODE_ENV || 'development',
  database: {
    url: databaseUrl,
    host: process.env.DB_HOST || 'localhost',
    port: parseInt(process.env.DB_PORT, 10) || 5432,
    name: process.env.DB_NAME || 'videoplatform',
    user: process.env.DB_USER || 'postgres',
    password: process.env.DB_PASSWORD || 'postgrespassword',
    ssl: process.env.DB_SSL === 'true',
  },
  jwt: {
    secret: jwtSecret,
    refreshSecret: jwtRefreshSecret,
    expiresIn: process.env.JWT_EXPIRES_IN || '8h',
    refreshExpiresIn: process.env.JWT_REFRESH_EXPIRES_IN || '7d',
  },
};
