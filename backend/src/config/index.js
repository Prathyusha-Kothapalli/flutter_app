const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '../../.env') });

const jwtSecret = process.env.JWT_SECRET || 'super_secret_jwt_access_token_key_2026_video_platform';
const jwtRefreshSecret = process.env.JWT_REFRESH_SECRET || 'super_secret_jwt_refresh_token_key_2026_video_platform';
const databaseUrl = process.env.DATABASE_URL || 'postgresql://neondb_owner:npg_mDwP3Vlr1XCe@ep-small-wildflower-b4kk195a-pooler.c-6.us-east-2.aws.neon.tech/neondb?sslmode=require&channel_binding=require';

module.exports = {
  port: parseInt(process.env.PORT, 10) || 5002,
  nodeEnv: process.env.NODE_ENV || 'production',
  database: {
    url: databaseUrl,
    host: process.env.DB_HOST || 'ep-small-wildflower-b4kk195a-pooler.c-6.us-east-2.aws.neon.tech',
    port: parseInt(process.env.DB_PORT, 10) || 5432,
    name: process.env.DB_NAME || 'neondb',
    user: process.env.DB_USER || 'neondb_owner',
    password: process.env.DB_PASSWORD || 'npg_mDwP3Vlr1XCe',
    ssl: true,
  },
  jwt: {
    secret: jwtSecret,
    refreshSecret: jwtRefreshSecret,
    expiresIn: process.env.JWT_EXPIRES_IN || '8h',
    refreshExpiresIn: process.env.JWT_REFRESH_EXPIRES_IN || '7d',
  },
};
