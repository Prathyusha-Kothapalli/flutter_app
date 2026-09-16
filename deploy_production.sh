#!/bin/bash
set -e

echo "=========================================="
echo "  Deploying to VPS 200.97.171.124"
echo "=========================================="

VPS="root@200.97.171.124"

# 1. Clone/pull latest code on VPS
ssh -o StrictHostKeyChecking=no $VPS << 'ENDSSH'
echo ">>> Pulling latest code..."
cd /root
if [ -d "flutter_app" ]; then
  cd flutter_app
  git pull origin main
else
  git clone https://github.com/Prathyusha-Kothapalli/flutter_app.git
  cd flutter_app
fi

# 2. Create backend .env for production
echo ">>> Creating production .env..."
cat > backend/.env << 'EOF'
PORT=5000
NODE_ENV=production
DATABASE_URL=postgresql://postgres:postgrespassword@localhost:5432/videoplatform
DB_HOST=localhost
DB_PORT=5432
DB_NAME=videoplatform
DB_USER=postgres
DB_PASSWORD=postgrespassword
DB_SSL=false
JWT_SECRET=super_secret_jwt_access_token_key_2026_video_platform
JWT_REFRESH_SECRET=super_secret_jwt_refresh_token_key_2026_video_platform
JWT_EXPIRES_IN=8h
JWT_REFRESH_EXPIRES_IN=7d
CORS_ORIGIN=https://elevateiq-softtech.com,http://elevateiq-softtech.com
ALLOW_HTTP=true
MAX_FILE_SIZE=524288000
EOF

# 3. Stop old containers
echo ">>> Stopping old containers..."
docker compose down 2>/dev/null || docker-compose down 2>/dev/null || true

# 4. Build and start containers
echo ">>> Building and starting containers..."
docker compose up --build -d 2>/dev/null || docker-compose up --build -d

# 5. Wait for health check
echo ">>> Waiting for backend to start..."
sleep 10

# 6. Check health
echo ">>> Checking health..."
curl -sf http://localhost:5000/health && echo " Backend is healthy!" || echo " Backend may still be starting..."

echo ""
echo "=========================================="
echo "  Deployment Complete!"
echo "=========================================="
echo "  Backend API: http://200.97.171.124:5000"
echo "  Health:      http://200.97.171.124:5000/health"
echo "=========================================="
ENDSSH

echo ""
echo "Done! Backend should be running at http://200.97.171.124:5000"
