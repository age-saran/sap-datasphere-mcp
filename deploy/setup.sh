#!/usr/bin/env bash
# ============================================================
# setup.sh — Deploy SAP Datasphere MCP on Hostinger VPS
# ============================================================
# Tested on Ubuntu 22.04 LTS
# Run as root or a user with sudo privileges:
#   bash setup.sh
# ============================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────
APP_DIR="/opt/sap-datasphere-mcp"
APP_USER="mcpuser"
PYTHON_BIN="python3"
SERVICE_NAME="sap-datasphere-mcp"
CLOUDFLARED_SERVICE="cloudflared"
REPO_URL="https://github.com/age-saran/sap-datasphere-mcp.git"   # change if needed

# Colours
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── 0. Root check ─────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Please run as root: sudo bash setup.sh"

# ── 1. System dependencies ────────────────────────────────────
info "Installing system dependencies..."
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv git curl wget unzip

# ── 2. Create app user ────────────────────────────────────────
if ! id "$APP_USER" &>/dev/null; then
    info "Creating system user: $APP_USER"
    useradd --system --shell /usr/sbin/nologin --home-dir "$APP_DIR" "$APP_USER"
fi

# ── 3. Clone / update repo ────────────────────────────────────
if [[ -d "$APP_DIR/.git" ]]; then
    info "Updating existing repo in $APP_DIR..."
    sudo -u "$APP_USER" git -C "$APP_DIR" pull --ff-only
else
    info "Cloning repo to $APP_DIR..."
    git clone "$REPO_URL" "$APP_DIR"
    chown -R "$APP_USER:$APP_USER" "$APP_DIR"
fi

# ── 4. Python virtualenv + dependencies ──────────────────────
info "Setting up Python virtualenv..."
sudo -u "$APP_USER" $PYTHON_BIN -m venv "$APP_DIR/venv"
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install --upgrade pip -q
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt" -q

# Install mcp>=1.2.0 explicitly (needed for Streamable HTTP transport)
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install "mcp>=1.2.0" -q

info "Python dependencies installed."

# ── 5. .env file ─────────────────────────────────────────────
if [[ ! -f "$APP_DIR/.env" ]]; then
    warn ".env file not found. Copying from .env.example..."
    cp "$APP_DIR/deploy/.env.example" "$APP_DIR/.env"
    chown "$APP_USER:$APP_USER" "$APP_DIR/.env"
    chmod 600 "$APP_DIR/.env"
    warn ">>> EDIT $APP_DIR/.env with your real credentials before starting the service <<<"
else
    info ".env already exists — skipping."
fi

# ── 6. Install MCP systemd service ───────────────────────────
info "Installing systemd service: $SERVICE_NAME..."
cp "$APP_DIR/deploy/$SERVICE_NAME.service" "/etc/systemd/system/$SERVICE_NAME.service"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"

# ── 7. Install cloudflared ────────────────────────────────────
if ! command -v cloudflared &>/dev/null; then
    info "Installing cloudflared..."
    ARCH=$(dpkg --print-architecture)
    wget -q "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb" \
        -O /tmp/cloudflared.deb
    dpkg -i /tmp/cloudflared.deb
    rm /tmp/cloudflared.deb
else
    info "cloudflared already installed: $(cloudflared --version)"
fi

# ── 8. Cloudflare Tunnel config ───────────────────────────────
TUNNEL_CONFIG_DIR="/etc/cloudflared"
TUNNEL_CONFIG="$TUNNEL_CONFIG_DIR/config.yml"

mkdir -p "$TUNNEL_CONFIG_DIR"

if [[ ! -f "$TUNNEL_CONFIG" ]]; then
    info "Copying cloudflared config template..."
    cp "$APP_DIR/deploy/cloudflared-config.yml" "$TUNNEL_CONFIG"
    warn ">>> EDIT $TUNNEL_CONFIG with your Cloudflare Tunnel token/ID <<<"
fi

# Install cloudflared as a system service
if ! systemctl is-enabled "$CLOUDFLARED_SERVICE" &>/dev/null 2>&1; then
    cp "$APP_DIR/deploy/$CLOUDFLARED_SERVICE.service" "/etc/systemd/system/$CLOUDFLARED_SERVICE.service"
    systemctl daemon-reload
    systemctl enable "$CLOUDFLARED_SERVICE"
fi

# ── 9. Summary ────────────────────────────────────────────────
echo ""
echo "============================================================"
echo " ✅ Setup complete!"
echo "============================================================"
echo ""
echo "Next steps:"
echo "  1. Edit: $APP_DIR/.env"
echo "     — Set MCP_HTTP_AUTH_TOKEN (strong random string)"
echo "     — Set DATASPHERE_* credentials"
echo ""
echo "  2. Authenticate Cloudflare Tunnel:"
echo "     cloudflared tunnel login"
echo "     cloudflared tunnel create sap-datasphere-mcp"
echo "     Then edit: $TUNNEL_CONFIG"
echo ""
echo "  3. Start services:"
echo "     systemctl start $SERVICE_NAME"
echo "     systemctl start $CLOUDFLARED_SERVICE"
echo ""
echo "  4. Verify:"
echo "     systemctl status $SERVICE_NAME"
echo "     curl https://YOUR-DOMAIN.example.com/health"
echo ""
echo "  Logs:"
echo "     journalctl -u $SERVICE_NAME -f"
echo "     journalctl -u $CLOUDFLARED_SERVICE -f"
echo "============================================================"
