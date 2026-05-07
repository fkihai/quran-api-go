# Production Deployment Plan — Quran API Go

> **Status:** Draft
> **Tanggal:** 2026-04-15
> **Versi Target:** MVP 1.0.0

---

## Daftar Isi

1. [Ringkasan Eksekutif](#1-ringkasan-eksekutif)
2. [Penilaian Kondisi Saat Ini](#2-penilaian-kondisi-saat-ini)
3. [Bug & Error yang Harus Ditangani](#3-bug--error-yang-harus-ditangani)
4. [Persyaratan Pre-Deployment](#4-persyaratan-pre-deployment)
5. [Arsitektur Production](#5-arsitektur-production)
6. [Konfigurasi Keamanan](#6-konfigurasi-keamanan)
7. [Proses Deployment](#7-proses-deployment)
8. [Verifikasi Post-Deployment](#8-verifikasi-post-deployment)
9. [Monitoring & Observability](#9-monitoring--observability)
10. [Rollback Plan](#10-rollback-plan)
11. [Checklist Rilis](#11-checklist-rilis)

---

## 1. Ringkasan Eksekutif

Dokumen ini merencanakan deployment Quran API Go ke lingkungan production. API ini melayani data Al-Quran (teks Arab, terjemahan ID/EN) untuk super app Ilmunara secara internal.

**Target Environment:**
- VPS/Linux server dengan nginx sebagai reverse proxy
- SQLite database (read-only setelah seeding)
- HTTPS wajib (belum aktif di konfigurasi saat ini)

**Batasan:**
- Layanan **internal only**, bukan public API
- Tidak ada autentikasi di MVP
- Tidak ada rate limiting middleware

---

## 2. Penilaian Kondisi Saat Ini

### 2.1 Kapabilitas yang Sudah Berfungsi

| Komponen | Status | Keterangan |
|----------|--------|------------|
| Endpoint Surah | ✅ | GET /surah, GET /surah/:id |
| Endpoint Ayat | ✅ | GET /surah/:id/ayah, GET /surah/:id/ayah/:number, GET /ayah/:id |
| Endpoint Juz | ✅ | GET /juz, GET /juz/:number |
| Pencarian FTS5 | ✅ | GET /search |
| Ayat Acak | ✅ | GET /random |
| Health Check | ✅ | GET /health, GET /health/ready |
| Database Seeding | ✅ | 114 surah, 6.236 ayat, 30 juz |
| CORS Middleware | ✅ | Konfigurasi via ALLOWED_ORIGINS |
| Logging | ✅ | zerolog structured logging |

### 2.2 Kapabilitas yang Belum/Belum Siap Production

| Komponen | Status | Keterangan |
|----------|--------|------------|
| HTTPS/SSL | ❌ | Belum dikonfigurasi (blok HTTPS di-comment) |
| Security Headers (lanjutan) | ⚠️ | CSP, HSTS belum ada |
| Rate Limiting | ⚠️ | Baru di nginx, belum di aplikasi |
| Unit Test Coverage | ⚠️ | Target 70% — perlu dicek |
| Documentation | ⚠️ | Scalar UI — perlu dicek kelengkapan |

### 2.3 Review Konfigurasi Nginx

```
Lokasi: deploy/nginx/quran-api.conf
```

**Temuan Keamanan:**

| Item | Severity | Status |
|------|----------|--------|
| HTTPS tidak aktif | KRITIS | ❌ Perlu aktivasi |
| X-XSS-Protection deprecated | LOW | ⚠️ Ganti dengan CSP |
| Content-Security-Policy hilang | MEDIUM | ❌ Perlu ditambahkan |
| Strict-Transport-Security hilang | HIGH | ❌ Perlu ditambahkan (jika HTTPS aktif) |
| Rate limiting nginx aktif | GOOD | ✅ 100r/s, burst=200 |
| Security headers dasar ada | GOOD | ✅ X-Frame-Options, X-Content-Type-Options |
| Proxy headers benar | GOOD | ✅ X-Real-IP, X-Forwarded-For |

---

## 3. Bug & Error yang Harus Ditangani

### 3.1 Bug Prioritas Tinggi (Wajib Fix Sebelum Rilis)

- [ ] **BUG-01: HTTPS belum dikonfigurasi**
  - Deskripsi: Blok SSL di nginx.conf di-comment, hanya HTTP port 80 yang aktif
  - Impact: Semua traffic plain text, data tidak terenkripsi
  - Solusi: Aktifkan blok HTTPS dengan sertifikat valid

- [ ] **BUG-02: Header X-XSS-Protection sudah deprecated**
  - Deskripsi: Chrome 78+ tidak menggunakan header ini, justru bisa interfere dengan CSP
  - Impact: Potensi false positive security scanner
  - Solusi: Hapus atau ganti dengan Content-Security-Policy yang proper

- [ ] **BUG-03: Cache-Control tidak ada untuk response API**
  - Deskripsi: Endpoint API umum tidak memiliki cache header
  - Impact: Client selalu fetch data, beban server tidak perlu
  - Solusi: Tambah Cache-Control untuk response yang cacheable

### 3.2 Bug Prioritas Sedang (Disarankan Fix Sebelum Rilis)

- [ ] **BUG-04: /health endpoint masih kena rate limiting**
  - Deskripsi: Di nginx.conf baris 92, /health tetap kena limit_req zone=api_limit
  - Impact: Load balancer/health checker bisa kena throttle
  - Solusi: Buat location /health dengan `limit_req off;`

- [ ] **BUG-05: Error response format tidak konsisten**
  - Deskripsi: Perlu dicek apakah semua error response mengikuti format standar { error, code, timestamp }
  - Solusi: Audit semua handler, pastikan pakai pkg/response

- [ ] **BUG-06: OpenAPI spec URL masih hardcoded localhost**
  - Deskripsi: Commit `d15ce94` menyebutkan "replace localhost:8080 with production URL"
  - Solusi: Pastikan Scalar docs membaca base URL dari environment

### 3.3 Bug Prioritas Rendah (Dapat Ditangani Setelah Rilis)

- [ ] **BUG-07: Timeout proxy 60s mungkin terlalu pendek**
  - Deskripsi: proxy_read_timeout 60s untuk database SQLite lokal
  - Impact: Kemungkinan timeout jika database besar dan load tinggi
  - Solusi: Evaluasi setelah load testing

- [ ] **BUG-08: Tidak ada endpoint untuk static assets caching**
  - Deskripsi: Konfigurasi static content (.txt, .md) ada tapi perlu dicek direktori
  - Solusi: Validasi path dan pastikan file ada

### 3.4 Bug yang Perlu Dikonfirmasi (Investigasi)

- [ ] **BUG-09: Coverage test mungkin belum 70%**
  - Deskripsi: PRD menyebutkan target 70% untuk handler dan repository
  - Solusi: Jalankan `go test ./... -cover` dan pastikan hasil ≥ 70%

- [ ] **BUG-10: Validasi input edge cases**
  - Deskripsi: Perlu dicek apakah validasi lang, ID, range sudah handle semua edge case
  - Solusi: Review validator di pkg/validator dan handler

---

## 4. Persyaratan Pre-Deployment

### 4.1 Persyaratan Teknis

```
✅ Go 1.22+ terinstall
✅ Nginx terinstall dan terkonfigurasi
✅ Domain/Subdomain sudah pointing ke server
✅ SSL Certificate (Let's Encrypt atau komersial)
✅ Docker (optional, untuk containerized deployment)
✅ systemd untuk service management
```

### 4.2 Persyaratan Keamanan

```
✅ SSL/TLS dengan TLS 1.2 minimum
✅ Security headers lengkap (CSP, HSTS, dll)
✅ Firewall configured (port 80, 443 only untuk web)
✅ Tidak ada credentials hardcoded
✅ Environment variables untuk konfigurasi sensitif
```

### 4.3 Persyaratan Operasional

```
✅ Monitoring aktif (Uptime monitoring, Logs)
✅ Backup strategy untuk SQLite database
✅ Runbook untuk incident response
✅ Komunikasi team tentang maintenance window
```

### 4.4 Persyaratan Legal/Compliance

```
✅ Lisensi data Al-Quran sudah dikonfirmasi
✅ Privacy Policy tersedia (jika required)
✅ Terms of Service tersedia (jika required)
```

---

## 5. Arsitektur Production

```
                    ┌─────────────────────────────────────────────────────┐
                    │                  SUPER APP                          │
                    │            (Internal Consumer)                      │
                    └─────────────────────┬───────────────────────────────┘
                                          │ HTTPS
                                          ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                              INTERNET / INTERNAL NETWORK                     │
└──────────────────────────────────────────────────────────────────────────────┘
                                          │
                                          ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                           NGINX REVERSE PROXY                                 │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │ - TLS Termination (HTTPS → HTTP)                                       │  │
│  │ - Rate Limiting (100r/s, burst=200)                                    │  │
│  │ - Gzip Compression                                                    │  │
│  │ - Security Headers                                                     │  │
│  │ - Proxy to Backend                                                     │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                               │
│  Listen: 443 (HTTPS), 80 (HTTP → 301 redirect)                               │
└─────────────────────────────────────┬────────────────────────────────────────┘
                                      │ HTTP (internal)
                                      ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                        QURAN API GO (Backend)                                 │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │ - Gin HTTP Framework                                                   │  │
│  │ - CORS Middleware (ALLOWED_ORIGINS)                                    │  │
│  │ - Logging Middleware (zerolog)                                         │  │
│  │ - Recovery Middleware                                                 │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                               │
│  Listen: 127.0.0.1:8080                                                      │
└─────────────────────────────────────┬────────────────────────────────────────┘
                                      │
                                      ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                           SQLITE DATABASE                                     │
│  Location: /opt/quran-api/data/quran.db                                      │
│  Size: ~50MB (estimated)                                                     │
│  Mode: Read-only after seeding                                               │
│  FTS5: Enabled for search                                                    │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 6. Konfigurasi Keamanan

### 6.1 Nginx Security Headers (Target)

Tambahkan di blok `server` HTTPS:

```nginx
# Security Headers
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "0" always;  # Deprecated, set to 0
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

# Content Security Policy (untuk API, cukup strict)
add_header Content-Security-Policy "default-src 'none'; frame-ancestors 'none';" always;

# HTTP Strict Transport Security (jika HTTPS aktif)
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
```

### 6.2 SSL Configuration

```nginx
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
ssl_prefer_server_ciphers off;
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
```

### 6.3 Rate Limiting

```nginx
limit_req_zone $binary_remote_addr zone=api_limit:10m rate=100r/s;

# /health bypass rate limiting
location /health {
    limit_req off;
    proxy_pass http://quran_api_backend;
}
```

### 6.4 Environment Variables Production

```bash
# /opt/quran-api/.env.production
DB_PATH=/opt/quran-api/data/quran.db
SERVER_PORT=8080
SERVER_HOST=127.0.0.1
ALLOWED_ORIGINS=https://[domain-superapp].com
APP_VERSION=1.0.0
LOG_LEVEL=info
```

---

## 7. Proses Deployment

### 7.1 Timeline Deployment

| Fase | Aktivitas | Durasi | Pelaku |
|------|-----------|--------|--------|
| 0 | Pre-deployment check & bug fixes | TBD | Dev Team |
| 1 | Provisioning server | 1-2 jam | DevOps |
| 2 | Setup SSL certificate | 30 menit | DevOps |
| 3 | Configure nginx | 1 jam | DevOps |
| 4 | Deploy application | 30 menit | DevOps |
| 5 | Database migration & seed | 15 menit | DevOps |
| 6 | Verification | 1-2 jam | QA/DevOps |
| 7 | DNS switch & cutover | 15 menit | DevOps |

### 7.2 Langkah Deployment Detail

#### Fase 0: Pre-Deployment (Wajib Selesai Sebelum Mulai)

```bash
# 1. Fix semua bug prioritas tinggi (BUG-01 s/d BUG-06)
# 2. Jalankan full test suite
cd /home/ubuntu/quran-api-go
go test ./... -cover

# 3. Build binary production
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o quran-api ./cmd/api

# 4. Verifikasi binary
./quran-api version  # atau ./quran-api migrate status
```

#### Fase 1: Server Provisioning

```bash
# 1. Login ke server production
ssh admin@production-server

# 2. Buat user untuk aplikasi
sudo useradd --system --no-create-home --shell /usr/sbin/nologin quran-api

# 3. Buat direktori
sudo mkdir -p /opt/quran-api/data /var/log/quran-api
sudo chown quran-api:quran-api /opt/quran-api/data /var/log/quran-api

# 4. Install dependensi
sudo apt update && sudo apt install -y nginx certbot python3-certbot-nginx
```

#### Fase 2: SSL Certificate

```bash
# 1. Dapatkan sertifikat Let's Encrypt
sudo certbot --nginx -d quran-api.example.com --non-interactive --agree-tos -m admin@example.com

# 2. Atau jika pakai Cloudflare/Wildcard:
# Gunakan DNS challenge atau Cloudflare origin certificate

# 3. Auto-renewal (otomatis oleh certbot)
sudo systemctl status certbot.timer
```

#### Fase 3: Konfigurasi Nginx

```bash
# 1. Copy konfigurasi
sudo cp /home/ubuntu/quran-api-go/deploy/nginx/quran-api.conf /etc/nginx/sites-available/quran-api

# 2. Edit konfigurasi — sesuaikan:
#    - server_name ke domain production
#    - ssl_certificate path
#    - Uncomment blok HTTPS
#    - Aktifkan security headers lengkap
#    - Fix /health rate limiting

# 3. Aktifkan site
sudo ln -sf /etc/nginx/sites-available/quran-api /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default  # hapus default

# 4. Test konfigurasi
sudo nginx -t

# 5. Reload nginx
sudo systemctl reload nginx
```

#### Fase 4: Deploy Application

```bash
# 1. Copy binary dan data
sudo cp /home/ubuntu/quran-api-go/quran-api /opt/quran-api/
sudo cp /home/ubuntu/quran-api-go/data/quran.db /opt/quran-api/data/
sudo cp /home/ubuntu/quran-api-go/.env.production /opt/quran-api/.env

# 2. Set permissions
sudo chown quran-api:quran-api /opt/quran-api/quran-api
sudo chmod +x /opt/quran-api/quran-api

# 3. Setup systemd service
sudo cp /home/ubuntu/quran-api-go/deploy/systemd/quran-api.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable quran-api

# 4. Setup logrotate
sudo cp /home/ubuntu/quran-api-go/deploy/logrotate/quran-api /etc/logrotate.d/quran-api
```

#### Fase 5: Database Migration & Seed (Jika Diperlukan)

```bash
# Untuk fresh install:
cd /opt/quran-api
sudo -u quran-api ./quran-api migrate up
sudo -u quran-api ./quran-api seed --data ./data/seed

# Untuk existing (data sudah ada):
# Skip fase ini
```

#### Fase 6: Start Services

```bash
# 1. Start aplikasi
sudo systemctl start quran-api

# 2. Cek status
sudo systemctl status quran-api

# 3. Cek health endpoint
curl -f http://127.0.0.1:8080/health
curl -f http://127.0.0.1:8080/health/ready
```

### 7.3 Docker Compose Deployment (Alternative)

```bash
# Build dan start dengan production override
docker-compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build

# Verifikasi
docker-compose logs -f api
curl -f https://quran-api.example.com/health
```

---

## 8. Verifikasi Post-Deployment

### 8.1 Smoke Test

```bash
BASE_URL="https://quran-api.example.com"

# 1. Health check
curl -f "$BASE_URL/health"
curl -f "$BASE_URL/health/ready"

# 2. Surah endpoints
curl -f "$BASE_URL/surah"
curl -f "$BASE_URL/surah/1"
curl -f "$BASE_URL/surah/1/ayah"
curl -f "$BASE_URL/surah/1/ayah/1"
curl -f "$BASE_URL/ayah/1"

# 3. Juz endpoints
curl -f "$BASE_URL/juz"
curl -f "$BASE_URL/juz/1"

# 4. Search
curl -f "$BASE_URL/search?q=Allah"

# 5. Random
curl -f "$BASE_URL/random"

# 6. Language parameter
curl -f "$BASE_URL/surah/1/ayah?lang=en"
curl -f "$BASE_URL/surah/1/ayah?lang=id"
```

### 8.2 Security Verification

```bash
# 1. Cek HTTPS redirect (HTTP → HTTPS)
curl -I http://quran-api.example.com/  # Harusnya 301 ke HTTPS

# 2. Cek SSL grade (gunakan sslyze atau browser)
# https://www.ssllabs.com/ssltest/

# 3. Cek security headers
curl -sI https://quran-api.example.com/ | grep -iE "x-frame|x-content|x-xss|strict-transport|content-security"

# 4. Cek rate limiting ( bombardier test)
# https://github.com/rakyll/hey
hey -n 1000 -c 100 https://quran-api.example.com/surah

# 5. Test CORS (harus gagal dengan origin random)
curl -H "Origin: https://malicious.com" -I https://quran-api.example.com/surah
# Harusnya tidak ada Access-Control-Allow-Origin header
```

### 8.3 Load Testing

```bash
# 1. Install hey (atau ab, wrk, k6)
go install github.com/rakyll/hey@latest

# 2. Basic load test
hey -n 10000 -c 50 https://quran-api.example.com/surah

# 3. Sequential endpoint test
hey -n 1000 -c 20 https://quran-api.example.com/surah/1/ayah

# 4. Search load test
hey -n 5000 -c 20 -d "q=Allah" https://quran-api.example.com/search

# Target: P95 < 200ms untuk surah, < 500ms untuk search
```

---

## 9. Monitoring & Observability

### 9.1 Metrics yang Harus Dimonitor

| Metric | Target | Alert Threshold |
|--------|--------|-----------------|
| HTTP Request Rate | Baseline | > 1000 RPS |
| Response Time P95 | < 200ms | > 500ms |
| Response Time P99 | < 500ms | > 1s |
| Error Rate | < 0.1% | > 1% |
| CPU Usage | < 70% | > 85% |
| Memory Usage | < 80% | > 90% |
| Disk Usage | < 70% | > 85% |
| Nginx Connection Status | - | > 10k connections |

### 9.2 Uptime Monitoring

```bash
# Setup uptime monitoring dengan:
# - UptimeRobot (free tier: 50 monitors)
# - Pingdom
# - Grafana + Prometheus
# - CloudWatch (jika AWS)

# Endpoint yang harus dimonitor:
# - GET /health (primary)
# - GET /health/ready (database connectivity)
# - GET /surah/1/ayah (functional test)
```

### 9.3 Log Aggregation

```bash
# Application logs (journalctl)
journalctl -u quran-api -f --since "1 hour ago"

# Nginx access logs
tail -f /var/log/nginx/quran-api-access.log

# Nginx error logs
tail -f /var/log/nginx/quran-api-error.log

# Centralized logging (jika ada):
# - ELK Stack (Elasticsearch, Logstash, Kibana)
# - Loki + Grafana
# - CloudWatch Logs
```

### 9.4 Dashboard Grafana (Contoh)

```
Panels:
1. Request Rate (requests/second)
2. Response Time (P50, P95, P99)
3. Error Rate by Status Code
4. Top Endpoints by Traffic
5. Nginx Worker Status
6. System Resources (CPU, Memory, Disk)
```

---

## 10. Rollback Plan

### 10.1 Kriteria Rollback

Lakukan rollback jika:
- Error rate > 5% selama > 5 menit
- Response time P95 > 2 detik
- Health check endpoint mengembalikan 503
- Critical security vulnerability ditemukan
- Data corruption terdeteksi

### 10.2 Prosedur Rollback

```bash
# Scenario A: Rollback application version

# 1. Identify previous working version
sudo systemctl stop quran-api

# 2. Restore previous binary (backup ada di /opt/quran-api/backups/)
sudo cp /opt/quran-api/backups/quran-api-v0.9.0 /opt/quran-api/quran-api
sudo chown quran-api:quran-api /opt/quran-api/quran-api

# 3. Restart
sudo systemctl start quran-api

# 4. Verify
curl -f http://127.0.0.1:8080/health
```

```bash
# Scenario B: Full rollback ke previous deployment

# 1. Restore dari backup directory
sudo systemctl stop quran-api

# 2. Restore database (jika diperlukan)
sudo cp /opt/quran-api/backups/quran.db.2026-04-10 /opt/quran-api/data/quran.db

# 3. Restore nginx config
sudo cp /etc/nginx/sites-available/quran-api /etc/nginx/sites-available/quran-api.new
sudo cp /etc/nginx/sites-available/quran-api.backup /etc/nginx/sites-available/quran-api
sudo nginx -t && sudo systemctl reload nginx

# 4. Restore application
sudo cp /opt/quran-api/backups/quran-api.2026-04-10 /opt/quran-api/quran-api

# 5. Restart
sudo systemctl start quran-api
```

### 10.3 Backup Schedule

```bash
# Daily backup script (crontab)
0 2 * * * /opt/quran-api/scripts/backup.sh

# backup.sh:
#!/bin/bash
DATE=$(date +%Y-%m-%d)
BACKUP_DIR=/opt/quran-api/backups
mkdir -p $BACKUP_DIR
cp /opt/quran-api/data/quran.db $BACKUP_DIR/quran.db.$DATE
cp /opt/quran-api/quran-api $BACKUP_DIR/quran-api.$DATE
cp /etc/nginx/sites-available/quran-api $BACKUP_DIR/quran-api.conf.$DATE
find $BACKUP_DIR -mtime +7 -delete  # Keep 7 days
```

---

## 11. Checklist Rilis

### 11.1 Pre-Release Checklist

```
PERSIAPAN
[ ] Semua bug prioritas tinggi (BUG-01 s/d BUG-06) sudah difix
[ ] Unit test coverage ≥ 70% (go test ./... -cover)
[ ] go vet ./... tidak ada error
[ ] gofmt -d . tidak ada diff
[ ] Build production binary berhasil (CGO_ENABLED=0 GOOS=linux GOARCH=amd64)

KONFIGURASI
[ ] SSL certificate sudah terinstall dan valid
[ ] HTTPS redirect HTTP → HTTPS berfungsi
[ ] Security headers lengkap (CSP, HSTS, X-Frame-Options, dll)
[ ] Rate limiting nginx aktif dan /health bypass
[ ] CORS ALLOWED_ORIGINS sudah diset ke domain production
[ ] Environment variables production sudah dikonfigurasi
[ ] Log rotation sudah configured

VERIFIKASI
[ ] Smoke test semua endpoint PASS
[ ] Security test (CORS, headers) PASS
[ ] Load test P95 < 200ms PASS
[ ] SSL grade minimal A- (ssllabs.com)
[ ] Health check endpoint berfungsi

DOKUMENTASI
[ ] README.md sudah updated dengan info deployment
[ ] Runbook sudah dibuat (backup, rollback, dll)
[ ] Team sudah briefed tentang deployment

 KOMUNIKASI
[ ] Maintenance window sudah diinformasikan
[ ] On-call schedule sudah diset
[ ] Escalation contacts sudah tersedia
```

### 11.2 Go-Live Checklist

```
SEBELUM CUTOVER
[ ] Backup complete (database, config, binary)
[ ] Rollback plan sudah tested
[ ] DNS TTL sudah diturunkan 24 jam sebelumnya
[ ] Monitoring dashboards sudah aktif

SAAT CUTOVER
[ ] Maintenance page (jika diperlukan)
[ ] Deploy new version
[ ] Verify health check
[ ] DNS switch
[ ] Clear CDN cache (jika ada)

SETELAH CUTOVER
[ ] Verifikasi semua endpoint berfungsi
[ ] Cek error rates (harus normal)
[ ] Cek response times (harus normal)
[ ] Update monitoring dashboards
[ ] Informasikan team bahwa deployment selesai
```

### 11.3 Post-Release Checklist (24-48 jam setelah)

```
MONITORING
[ ] Error rate normal (< 0.1%)
[ ] Response time normal (P95 < 200ms)
[ ] No new critical logs
[ ] Uptime 100% (tidak ada unexpected restart)

COMMUNICATION
[ ] Deployment success announcement
[ ] Update monitoring dashboards
[ ] Update on-call schedule if needed

DOCUMENTATION
[ ] Document any issues encountered
[ ] Update runbook if needed
[ ] Record lessons learned
```

---

## Lampiran

### A. File Locations

```
/opt/quran-api/
├── quran-api              # Application binary
├── .env                   # Environment variables
├── data/
│   └── quran.db           # SQLite database
└── backups/               # Backup directory

/etc/nginx/sites-available/
└── quran-api              # Nginx configuration

/etc/systemd/system/
└── quran-api.service     # Systemd service file

/etc/logrotate.d/
└── quran-api              # Logrotate config

/var/log/
├── nginx/
│   ├── quran-api-access.log
│   └── quran-api-error.log
└── quran-api/             # Application logs (journalctl)
```

### B. Emergency Contacts

| Role | Name | Contact |
|------|------|---------|
| DevOps Lead | TBD | TBD |
| Backend Lead | TBD | TBD |
| On-Call (24/7) | TBD | TBD |

### C. Relevant Documentation

- [PRD Document](./prd-quran-api-go-2nd.md)
- [Contributing Guide](./CONTRIBUTING.md)
- [Deployment README](../deploy/README.md)
- [AGENTS.md](../AGENTS.md)

---

*Last Updated: 2026-04-15*
*Document Owner: Dev Team*
