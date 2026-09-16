# Video Data Collection & Vendor Management Platform

A production-ready enterprise platform for managing video data collection workflows, vendor operations, task allocation, quality control (QC), and dataset distribution.

---

## 🐳 1-Click Docker Setup (Easiest Way to Run!)

Run the entire platform (**PostgreSQL Database**, **Node.js Express Backend**, and **Flutter Web Frontend**) with a single click!

### Windows:
Double-click `docker-start.bat` in the root folder!

### Linux / macOS:
```bash
chmod +x docker-start.sh
./docker-start.sh
```

Or manually using Docker Compose:
```bash
docker compose up --build -d
```

### 🌐 Access Ports:
- 📱 **Web Application Portal**: [http://localhost:8081](http://localhost:8081)
- ⚡ **Express REST API Server**: [http://localhost:5000/api/v1](http://localhost:5000/api/v1)
- 🗄️ **PostgreSQL Database**: `localhost:5432`

---

## Technology Stack

- **Mobile & Web App**: Flutter (Cross-platform)
- **Backend API**: Node.js + Express.js
- **Database**: PostgreSQL (Neon Cloud / Local Containerized)
- **Containerization**: Docker & Docker Compose
- **Version Control**: Git

---

## Folder Structure

```
video-platform/
├── backend/            # Express.js REST API server (Node.js)
├── mobile-app/         # Cross-platform mobile & web app (Flutter)
├── database/           # DB migrations, seeds, schema files
├── docs/               # Architecture & API documentation
├── docker/             # Containerization files
├── docker-compose.yml  # Docker Compose orchestration
├── docker-start.bat    # Windows 1-Click launcher
├── docker-start.sh     # macOS/Linux 1-Click launcher
└── README.md           # Master project documentation
```

---

## How to Run Manually

### 1. Backend (`backend/`)
```bash
cd backend
npm install
npm run dev
```

### 2. Mobile & Web App (`mobile-app/`)
```bash
cd mobile-app
flutter pub get
flutter run -d web-server --web-port 8081
```
"# flutter_app" 
