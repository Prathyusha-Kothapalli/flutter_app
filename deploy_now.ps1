# ============================================================
# Video Platform - One-Click VPS Deployment Script
# VPS: 195.35.21.139 (elevateiq-softtech.com)
# ============================================================

$VPS_IP   = "195.35.21.139"
$VPS_USER = "root"
$REPO_URL = "https://github.com/pittaanji9390-afk/video-platform.git"
$APP_DIR  = "/root/video-platform-backend"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  VIDEO PLATFORM - HOSTINGER VPS DEPLOYMENT" -ForegroundColor Cyan
Write-Host "  Target: $VPS_USER@$VPS_IP" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Install Posh-SSH if needed
if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
    Write-Host "==> Installing Posh-SSH module..." -ForegroundColor Yellow
    Install-Module -Name Posh-SSH -Force -Scope CurrentUser -AllowClobber 2>&1 | Out-Null
}
Import-Module Posh-SSH -ErrorAction Stop

# Get VPS password securely
$VPS_PASS = Read-Host "Enter VPS root password" -AsSecureString
$Credential = New-Object System.Management.Automation.PSCredential($VPS_USER, $VPS_PASS)

# Connect
Write-Host "`n==> [1/6] Connecting to VPS $VPS_IP ..." -ForegroundColor Cyan
$session = New-SSHSession -ComputerName $VPS_IP -Credential $Credential -AcceptKey -Force
if (-not $session) { Write-Error "SSH connection failed!"; exit 1 }
Write-Host "    Connected!" -ForegroundColor Green

function Run($cmd, $label="") {
    if ($label) { Write-Host "    > $label" -ForegroundColor DarkGray }
    $result = Invoke-SSHCommand -SessionId $session.SessionId -Command $cmd -TimeOut 300
    if ($result.Output -and $result.Output.Trim()) { Write-Host $result.Output -ForegroundColor White }
    if ($result.Error  -and $result.Error.Trim())  { Write-Host $result.Error  -ForegroundColor Yellow }
    return $result
}

# ---- STEP 2: Check & Install Docker ----
Write-Host "`n==> [2/6] Checking Docker..." -ForegroundColor Cyan
Run "docker --version 2>/dev/null || (curl -fsSL https://get.docker.com | sh && systemctl enable docker && systemctl start docker)" "Docker check/install"
Run "docker compose version 2>/dev/null || apt-get install -y docker-compose-plugin" "Docker Compose check"

# ---- STEP 3: Clone or Update Repo ----
Write-Host "`n==> [3/6] Cloning/updating repository..." -ForegroundColor Cyan
Run @"
if [ -d '$APP_DIR/.git' ]; then
    echo 'Repo exists — pulling latest changes...'
    cd '$APP_DIR' && git fetch origin && git reset --hard origin/main && git pull origin main
else
    echo 'Cloning fresh repository...'
    rm -rf '$APP_DIR'
    git clone '$REPO_URL' '$APP_DIR'
fi
"@ "Git clone/pull"

# ---- STEP 4: Write .env on VPS ----
Write-Host "`n==> [4/6] Writing production .env on VPS..." -ForegroundColor Cyan
$envFile = @"
PORT=5000
NODE_ENV=production
DATABASE_URL=postgresql://neondb_owner:npg_mDwP3Vlr1XCe@ep-small-wildflower-b4kk195a-pooler.c-6.us-east-2.aws.neon.tech/neondb?sslmode=require&channel_binding=require
DB_HOST=ep-small-wildflower-b4kk195a-pooler.c-6.us-east-2.aws.neon.tech
DB_PORT=5432
DB_NAME=neondb
DB_USER=neondb_owner
DB_PASSWORD=npg_mDwP3Vlr1XCe
DB_SSL=true
JWT_SECRET=super_secret_jwt_access_token_key_2026_video_platform
JWT_REFRESH_SECRET=super_secret_jwt_refresh_token_key_2026_video_platform
JWT_EXPIRES_IN=8h
JWT_REFRESH_EXPIRES_IN=7d
CORS_ORIGIN=https://elevateiq-softtech.com,http://elevateiq-softtech.com
ALLOW_HTTP=false
"@

# Write each line via SSH
$lines = $envFile -split "`n"
Run "rm -f '$APP_DIR/backend/.env'" "Clear old .env"
foreach ($line in $lines) {
    $line = $line.Trim()
    if ($line -ne "") {
        Run "echo '$line' >> '$APP_DIR/backend/.env'" ""
    }
}
Run "echo '.env written:' && cat '$APP_DIR/backend/.env'" "Verify .env"

# ---- STEP 5: Docker Compose Up ----
Write-Host "`n==> [5/6] Building and starting Docker containers..." -ForegroundColor Cyan
Run "cd '$APP_DIR' && docker compose down --remove-orphans 2>/dev/null || true" "Stop old containers"
Run "cd '$APP_DIR' && docker compose pull 2>/dev/null || true" "Pull base images"
Run "cd '$APP_DIR' && docker compose up --build -d 2>&1 | tail -30" "docker compose up"
Run "sleep 20 && docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'" "Container status"

# ---- STEP 6: Configure Nginx ----
Write-Host "`n==> [6/6] Configuring Nginx reverse proxy..." -ForegroundColor Cyan

$nginxSnippet = @"
    # === Video Platform Routes ===
    location /video-platform-api/ {
        proxy_pass http://127.0.0.1:5000/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 86400;
    }
    location /video-platform/ {
        proxy_pass http://127.0.0.1:8081/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
"@

Run "cat > /etc/nginx/snippets/video-platform.conf << 'NGINXEOF'`n$nginxSnippet`nNGINXEOF" "Write Nginx snippet"

Run @"
CONF=\$(grep -rl 'elevateiq-softtech.com\|server_name' /etc/nginx/sites-enabled/ 2>/dev/null | head -1)
if [ -n "\$CONF" ]; then
    if ! grep -q 'video-platform' "\$CONF"; then
        sed -i '/server_name/a\\    include /etc/nginx/snippets/video-platform.conf;' "\$CONF"
        echo "Injected routes into: \$CONF"
    else
        echo "Routes already in: \$CONF"
    fi
else
    echo "WARNING: No Nginx server config found — add include manually"
fi
"@ "Inject Nginx include"

Run "nginx -t && systemctl reload nginx && echo 'Nginx OK'" "Test & reload Nginx"

# ---- Health Check ----
Write-Host "`n==> Health check..." -ForegroundColor Cyan
Run "curl -sf http://localhost:5000/health || echo 'Backend not responding yet (may still be starting)'" "Local health check"
Run "curl -sf https://elevateiq-softtech.com/video-platform-api/health || echo 'HTTPS endpoint check'" "HTTPS health check"

# ---- Done ----
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  DEPLOYMENT COMPLETE!" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  API     : https://elevateiq-softtech.com/video-platform-api/api/v1/" -ForegroundColor Cyan
Write-Host "  Frontend: https://elevateiq-softtech.com/video-platform/" -ForegroundColor Cyan
Write-Host "  Health  : https://elevateiq-softtech.com/video-platform-api/health" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Admin Login:   admin@gmail.com / admin123" -ForegroundColor Yellow
Write-Host "  QC Login:      qcteam@gmail.com / qcteam123" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Green

Remove-SSHSession -SessionId $session.SessionId
