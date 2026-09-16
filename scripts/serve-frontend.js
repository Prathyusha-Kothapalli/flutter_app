const express = require(require('path').join(__dirname, '../backend/node_modules/express'));
const path = require('path');
const http = require('http');

const app = express();
const PORT = 8081;
const BACKEND_PORT = 5000;

// Resolve Flutter web build directory
let webDir = path.join(__dirname, '../mobile-app/build/web');
const fs = require('fs');
if (!fs.existsSync(webDir)) {
  webDir = path.join(__dirname, '../backend/src/public');
}

// Security & CORS headers for Flutter Web
app.use((req, res, next) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, PATCH, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', '*');
  res.setHeader('Cross-Origin-Opener-Policy', 'same-origin-allow-popups');
  res.setHeader('Cross-Origin-Embedder-Policy', 'credentialless');

  if (req.method === 'OPTIONS') {
    return res.sendStatus(200);
  }
  next();
});

// Proxy API & health requests to backend on port 5000
app.use(['/api', '/health', '/uploads'], (req, res) => {
  const options = {
    hostname: '127.0.0.1',
    port: BACKEND_PORT,
    path: req.originalUrl,
    method: req.method,
    headers: {
      ...req.headers,
      host: `127.0.0.1:${BACKEND_PORT}`,
    },
  };

  const proxyReq = http.request(options, (proxyRes) => {
    res.writeHead(proxyRes.statusCode, proxyRes.headers);
    proxyRes.pipe(res, { end: true });
  });

  proxyReq.on('error', (err) => {
    res.status(502).json({
      error: 'Backend API unavailable on port ' + BACKEND_PORT,
      details: err.message,
    });
  });

  req.pipe(proxyReq, { end: true });
});

// Serve static assets with correct MIME types and cache headers
app.use(express.static(webDir, {
  setHeaders: (res, filePath) => {
    if (filePath.endsWith('.wasm')) {
      res.setHeader('Content-Type', 'application/wasm');
    }
    if (filePath.endsWith('.js') || filePath.endsWith('.html') || filePath.endsWith('.json')) {
      res.setHeader('Cache-Control', 'no-cache, no-store, must-revalidate');
      res.setHeader('Pragma', 'no-cache');
      res.setHeader('Expires', '0');
    }
  },
}));

// SPA Fallback: send index.html for all unrecognized frontend routes
app.get('*', (req, res) => {
  const indexPath = path.join(webDir, 'index.html');
  if (fs.existsSync(indexPath)) {
    res.setHeader('Cache-Control', 'no-cache, no-store, must-revalidate');
    res.sendFile(indexPath);
  } else {
    res.status(404).send('Frontend build not found');
  }
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`=======================================================`);
  console.log(`🚀 Video Platform Web Application running at:`);
  console.log(`   Local URL:    http://localhost:${PORT}`);
  console.log(`   Network URL:  http://127.0.0.1:${PORT}`);
  console.log(`   Serving:      ${webDir}`);
  console.log(`   API Proxy:    http://127.0.0.1:${BACKEND_PORT}/api/v1`);
  console.log(`=======================================================`);
});
