#!/usr/bin/env bash
# ============================================================
# update.sh — Pull latest code and restart services
# Usage: sudo bash update.sh
# ============================================================

set -euo pipefail

APP_DIR="/opt/sap-datasphere-mcp"
APP_USER="mcpuser"
SERVICE_NAME="sap-datasphere-mcp"

GREEN='\033[0;32m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }

[[ $EUID -ne 0 ]] && { echo "Run as root: sudo bash update.sh"; exit 1; }

info "Pulling latest code..."
sudo -u "$APP_USER" git -C "$APP_DIR" pull --ff-only

info "Updating Python dependencies..."
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt" -q
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install "mcp>=1.2.0" -q

info "Restarting $SERVICE_NAME..."
systemctl restart "$SERVICE_NAME"

sleep 2
systemctl is-active --quiet "$SERVICE_NAME" \
    && info "✅ Service is running" \
    || { echo "❌ Service failed to start"; journalctl -u "$SERVICE_NAME" -n 30; exit 1; }
