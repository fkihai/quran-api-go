#!/bin/bash
# =============================================================================
# Quran API Go - Production Deployment Script
# =============================================================================
# Usage: ./deploy.sh [--build-only] [--skip-migrate] [--skip-seed]
#
# This script deploys Quran API Go to production following best practices:
# - Builds Docker image or binary
# - Creates dedicated user and directory
# - Sets up systemd service
# - Configures Nginx reverse proxy
# - Sets up log rotation
# - Runs database migrations and seeding
# =============================================================================

set -euo pipefail

# Configuration
APP_NAME="quran-api"
APP_USER="quran-api"
APP_GROUP="quran-api"
INSTALL_DIR="/opt/${APP_NAME}"
DATA_DIR="${INSTALL_DIR}/data"
LOG_DIR="/var/log/${APP_NAME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."

# Flags
SKIP_MIGRATE=false
SKIP_SEED=false
BUILD_ONLY=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --build-only)
            BUILD_ONLY=true
            shift
            ;;
        --skip-migrate)
            SKIP_MIGRATE=true
            shift
            ;;
        --skip-seed)
            SKIP_SEED=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--build-only] [--skip-migrate] [--skip-seed]"
            echo ""
            echo "Options:"
            echo "  --build-only   Build the application without deploying"
            echo "  --skip-migrate Skip database migration"
            echo "  --skip-seed    Skip database seeding"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing=()

    if ! command -v go &> /dev/null; then
        missing+=("golang")
    fi

    if ! command -v docker &> /dev/null; then
        missing+=("docker")
    fi

    if ! command -v nginx &> /dev/null; then
        missing+=("nginx")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing prerequisites: ${missing[*]}"
        echo "Install with: sudo apt install ${missing[*]}"
        exit 1
    fi

    log_success "All prerequisites satisfied"
}

# Create application user
create_user() {
    log_info "Creating application user..."
    if id "${APP_USER}" &>/dev/null; then
        log_warn "User ${APP_USER} already exists, skipping"
    else
        useradd --system --no-create-home --shell /usr/sbin/nologin --group "${APP_GROUP}" || groupadd "${APP_GROUP}"
        usermod -aG "${APP_GROUP}" "${APP_USER}"
        log_success "User ${APP_USER} created"
    fi
}

# Create directory structure
create_directories() {
    log_info "Creating directory structure..."

    mkdir -p "${INSTALL_DIR}"
    mkdir -p "${DATA_DIR}"
    mkdir -p "${LOG_DIR}"
    mkdir -p "${INSTALL_DIR}/migrations"
    mkdir -p "${INSTALL_DIR}/data/seed"

    # Set permissions
    chown -R "${APP_USER}:${APP_GROUP}" "${INSTALL_DIR}"
    chown -R "${APP_USER}:${APP_GROUP}" "${LOG_DIR}"

    log_success "Directory structure created"
}

# Build the application
build_app() {
    log_info "Building application..."

    cd "${PROJECT_DIR}"

    if command -v docker &> /dev/null && docker info &>/dev/null; then
        log_info "Using Docker to build..."
        docker build -t "${APP_NAME}:production" .
        docker create --name "${APP_NAME}-builder" "${APP_NAME}:production" /bin/true
        docker cp "${APP_NAME}-builder:/app/quran-api" "${INSTALL_DIR}/quran-api"
        docker rm "${APP_NAME}-builder"
    else
        log_info "Using Go to build..."
        CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "${INSTALL_DIR}/quran-api" ./cmd/api
    fi

    # Copy migrations
    cp -r "${PROJECT_DIR}/migrations/"* "${INSTALL_DIR}/migrations/"

    chown "${APP_USER}:${APP_GROUP}" "${INSTALL_DIR}/quran-api"
    chmod 755 "${INSTALL_DIR}/quran-api"

    log_success "Application built"
}

# Setup environment file
setup_env() {
    log_info "Setting up environment file..."

    if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
        cp "${PROJECT_DIR}/.env.production" "${INSTALL_DIR}/.env"
        chmod 640 "${INSTALL_DIR}/.env"
        chown root:"${APP_GROUP}" "${INSTALL_DIR}/.env"
        log_success "Environment file created"
    else
        log_warn "Environment file already exists, skipping"
    fi
}

# Setup systemd service
setup_systemd() {
    log_info "Setting up systemd service..."

    cat > "/etc/systemd/system/${APP_NAME}.service" << EOF
[Unit]
Description=Quran API Go - Lightweight RESTful API untuk Data Al-Quran
Documentation=https://github.com/Yayasan-Digital-Islami-Indonesia/quran-api-go
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
ExecStart=${INSTALL_DIR}/quran-api
Restart=always
RestartSec=5s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${APP_NAME}
TimeoutStopSec=30

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=${INSTALL_DIR}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log_success "Systemd service installed"
}

# Setup Nginx
setup_nginx() {
    log_info "Setting up Nginx reverse proxy..."

    cat > "/etc/nginx/sites-available/${APP_NAME}" << EOF
upstream ${APP_NAME}_backend {
    server 127.0.0.1:8080;
    keepalive 32;
}

server {
    listen 80;
    listen [::]:80;
    server_name localhost;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_types text/plain application/json application/javascript text/css text/xml text/javascript;

    # Logging
    access_log ${LOG_DIR}/access.log;
    error_log ${LOG_DIR}/error.log warn;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    # Rate limiting
    limit_req_zone \$binary_remote_addr zone=api_limit:10m rate=100r/s;
    limit_req zone=api_limit burst=200 nodelay;

    # Proxy settings
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Connection "";

    proxy_connect_timeout 60s;
    proxy_send_timeout 60s;
    proxy_read_timeout 60s;

    location / {
        proxy_pass http://${APP_NAME}_backend;
    }
}
EOF

    # Enable site
    ln -sf "/etc/nginx/sites-available/${APP_NAME}" "/etc/nginx/sites-enabled/${APP_NAME}"

    # Remove default site if exists
    rm -f /etc/nginx/sites-enabled/default

    # Test nginx config
    nginx -t

    log_success "Nginx configured"
}

# Setup log rotation
setup_logrotate() {
    log_info "Setting up log rotation..."

    cat > "/etc/logrotate.d/${APP_NAME}" << EOF
${LOG_DIR}/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 ${APP_USER} ${APP_GROUP}
    sharedscripts
    postrotate
        systemctl reload ${APP_NAME} 2>/dev/null || true
    endscript
}
EOF

    log_success "Log rotation configured"
}

# Run database migrations
run_migrations() {
    if [[ "${SKIP_MIGRATE}" == "true" ]]; then
        log_warn "Skipping migrations (--skip-migrate)"
        return
    fi

    log_info "Running database migrations..."

    cd "${INSTALL_DIR}"
    sudo -u "${APP_USER}" ./quran-api migrate up

    log_success "Migrations completed"
}

# Seed database
seed_database() {
    if [[ "${SKIP_SEED}" == "true" ]]; then
        log_warn "Skipping seed (--skip-seed)"
        return
    fi

    log_info "Seeding database..."

    if [[ ! -d "${INSTALL_DIR}/data/seed" ]]; then
        log_warn "Seed directory not found, copying from project..."
        mkdir -p "${INSTALL_DIR}/data/seed"
        cp -r "${PROJECT_DIR}/data/seed/"* "${INSTALL_DIR}/data/seed/" 2>/dev/null || true
    fi

    cd "${INSTALL_DIR}"
    sudo -u "${APP_USER}" ./quran-api seed --data ./data/seed

    log_success "Database seeded"
}

# Start services
start_services() {
    log_info "Starting services..."

    systemctl enable "${APP_NAME}"
    systemctl restart "${APP_NAME}"

    systemctl reload nginx
    systemctl enable nginx
    systemctl restart nginx

    log_success "Services started"
}

# Verify deployment
verify_deployment() {
    log_info "Verifying deployment..."

    local max_attempts=30
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if curl -sf "http://localhost:8080/health" > /dev/null 2>&1; then
            log_success "Health check passed!"
            echo ""
            echo "=========================================="
            echo "  Quran API Go deployed successfully!"
            echo "=========================================="
            echo ""
            echo "  Local:   http://localhost:8080"
            echo "  API:     http://localhost:8080/surah"
            echo "  Docs:    http://localhost:8080/docs"
            echo "  Health:  http://localhost:8080/health"
            echo ""
            echo "  Service: systemctl status ${APP_NAME}"
            echo "  Logs:    journalctl -u ${APP_NAME} -f"
            echo "=========================================="
            echo ""
            return 0
        fi

        log_info "Waiting for service... (${attempt}/${max_attempts})"
        sleep 2
        ((attempt++))
    done

    log_error "Health check failed after ${max_attempts} attempts"
    log_error "Check logs with: journalctl -u ${APP_NAME} -n 50"
    exit 1
}

# Main deployment flow
main() {
    echo ""
    echo "=========================================="
    echo "  Quran API Go - Deployment Script"
    echo "=========================================="
    echo ""

    check_prerequisites

    if [[ "${BUILD_ONLY}" == "true" ]]; then
        log_info "Build-only mode, skipping deployment"
        build_app
        log_success "Build completed"
        exit 0
    fi

    check_root
    create_user
    create_directories
    build_app
    setup_env
    setup_systemd
    setup_nginx
    setup_logrotate
    run_migrations
    seed_database
    start_services
    verify_deployment
}

main
