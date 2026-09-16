# Node.js Express Backend Dockerfile
FROM node:18-alpine

# Install ffmpeg and ffprobe for video processing
RUN apk add --no-cache ffmpeg

WORKDIR /app

# Copy package manifests first for caching layers
COPY package*.json ./

# Install dependencies
RUN npm install --only=production

# Copy application source code
COPY . .

# Create uploads directory and set permissions
RUN mkdir -p /app/uploads/videos && chown -R node:node /app

# Switch to non-root user
USER node

# Expose Node.js server port
EXPOSE 5000

# Start server
CMD ["node", "src/server.js"]
