# Deployment Guide - Quran API Go

## Quick Start (Development/Testing)

```bash
# Using Docker Compose
docker-compose up -d --build

# Or using Make
make migrate
make seed
make run
```

## Production Deployment

### Prerequisites

```bash
# Install required packages
sudo apt install -y golang nginx docker.io docker-compose
```

### Deploy Script

The easiest way to deploy to production:

```bash
# Full deployment
sudo ./deploy/deploy.sh

# With options
sudo ./deploy/deploy.sh --skip-seed    # Skip seeding if data exists
sudo ./deploy/deploy.sh --skip-migrate # Skip migrations
sudo ./deploy/deploy.sh --build-only   # Only build, don't deploy
```

### Manual Deployment

```bash
# 1. Create user and directories
sudo useradd --system --no-create-home --shell /usr/sbin/nologin quran-api
sudo mkdir -p /opt/quran-api/data /var/log/quran-api

# 2. Build
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /opt/quran-api/quran-api ./cmd/api

# 3. Setup environment
sudo cp .env.production /opt/quran-api/.env

# 4. Setup systemd
sudo cp deploy/systemd/quran-api.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable quran-api

# 5. Setup Nginx
sudo cp deploy/nginx/quran-api.conf /etc/nginx/sites-available/quran-api
sudo ln -sf /etc/nginx/sites-available/quran-api /etc/nginx/sites-enabled/
sudo nginx -t

# 6. Setup log rotation
sudo cp deploy/logrotate/quran-api /etc/logrotate.d/quran-api

# 7. Run migrations and seed
cd /opt/quran-api
sudo -u quran-api ./quran-api migrate up
sudo -u quran-api ./quran-api seed --data ./data/seed

# 8. Start services
sudo systemctl restart quran-api nginx
```

## Docker Compose (Production)

```bash
# Build and run with production overrides
docker-compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build

# View logs
docker-compose logs -f api

# Check health
curl http://localhost:8080/health
```

## Post-Deployment

### Verify

```bash
# Check service status
sudo systemctl status quran-api

# Test endpoints
curl http://localhost:8080/health
curl http://localhost:8080/surah
curl http://localhost:8080/surah/1/ayah?lang=id
```

### Logs

```bash
# Application logs
sudo journalctl -u quran-api -f

# Nginx access logs
sudo tail -f /var/log/quran-api/access.log

# Nginx error logs
sudo tail -f /var/log/quran-api/error.log
```

### Troubleshooting

```bash
# Check if service is running
sudo systemctl is-active quran-api

# Check service logs
sudo journalctl -u quran-api -n 100 --no-pager

# Restart service
sudo systemctl restart quran-api

# Rebuild and redeploy
sudo ./deploy/deploy.sh
```

## SSL/HTTPS Setup

1. Install Certbot:
   ```bash
   sudo apt install -y certbot python3-certbot-nginx
   ```

2. Obtain certificate:
   ```bash
   sudo certbot --nginx -d quran-api.example.com
   ```

3. Auto-renewal is automatic with Certbot.

## Monitoring

The API exposes Prometheus-compatible metrics at `/metrics` (if enabled in build).

Configure monitoring with:
- Prometheus (scrape `/metrics`)
- Grafana dashboards
- Uptime monitoring (uptimerobot, pingdom, etc.)
