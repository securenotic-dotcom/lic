#!/bin/bash
#==============================================================================
# cPanel & WHM Free Trial Installer for Ubuntu VPS
#------------------------------------------------------------------------------
# Description : Installs cPanel & WHM on Ubuntu and activates a 15-day
#               free trial license automatically from cpanel.net.
# Supported OS: Ubuntu 20.04 LTS, Ubuntu 22.04 LTS (x86_64)
# Usage       : sudo bash install-cpanel-trial-ubuntu.sh
# Author      : Sysadmin Toolkit
# License     : MIT
#==============================================================================

set -e

# ---------- Colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
info() { echo -e "${BLUE}[STEP]${NC}  $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

clear
echo -e "${BLUE}=====================================================${NC}"
echo -e "${BLUE}  cPanel & WHM License Installer for VPS   ${NC}"
echo -e "${BLUE}         1 Monthly Licensel • Auto-Activated               ${NC}"
echo -e "${BLUE}=====================================================${NC}\n"

# ---------- Step 1: Root check ----------
info "Step 1/8 - Checking root privileges..."
if [ "$EUID" -ne 0 ]; then
  err "This script must be run as root. Try: sudo bash $0"
fi
log "Running as root. OK."

# ---------- Step 2: OS check (must be Ubuntu 20.04 or 22.04) ----------
info "Step 2/8 - Verifying operating system..."
if [ ! -f /etc/os-release ]; then
  err "Cannot detect OS. /etc/os-release not found."
fi

. /etc/os-release
if [ "$ID" != "ubuntu" ]; then
  err "This script only supports Ubuntu. Detected: $ID"
fi

case "$VERSION_ID" in
  20.04|22.04)
    log "Detected Ubuntu $VERSION_ID ($VERSION_CODENAME). Supported."
    ;;
  *)
    err "Unsupported Ubuntu version: $VERSION_ID. Requires 20.04 or 22.04."
    ;;
esac

# ---------- Step 3: Architecture check ----------
info "Step 3/8 - Checking system architecture..."
ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
  err "cPanel requires x86_64 architecture. Found: $ARCH"
fi
log "Architecture: $ARCH. OK."

# ---------- Step 4: RAM check ----------
info "Step 4/8 - Checking RAM..."
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
if [ "$TOTAL_RAM" -lt 1024 ]; then
  err "Insufficient RAM: ${TOTAL_RAM}MB. cPanel requires at least 1024MB."
elif [ "$TOTAL_RAM" -lt 2048 ]; then
  warn "Only ${TOTAL_RAM}MB RAM detected. 2GB+ is recommended."
else
  log "RAM: ${TOTAL_RAM}MB. OK."
fi

# ---------- Step 5: Hostname (FQDN) ----------
info "Step 5/8 - Verifying hostname (FQDN required)..."
CURRENT_HOSTNAME=$(hostname -f 2>/dev/null || hostname)

if [[ ! "$CURRENT_HOSTNAME" =~ \..+\. ]] &&
   [[ ! "$CURRENT_HOSTNAME" =~ ^[a-zA-Z0-9-]+\.[a-zA-Z0-9-]+\.[a-zA-Z]{2,}$ ]]; then
  warn "Current hostname '$CURRENT_HOSTNAME' is not a valid FQDN."
  read -p "Enter a fully-qualified hostname (e.g. server.example.com): " NEW_HOST
  if [[ ! "$NEW_HOST" =~ ^[a-zA-Z0-9-]+\.[a-zA-Z0-9-]+\.[a-zA-Z]{2,}$ ]]; then
    err "Invalid FQDN. Must be like: server.example.com"
  fi
  hostnamectl set-hostname "$NEW_HOST"
  echo "127.0.0.1 $NEW_HOST" >> /etc/hosts
  log "Hostname set to: $NEW_HOST"
else
  log "Hostname: $CURRENT_HOSTNAME. OK."
fi

# ---------- Step 6: Update system & install prerequisites ----------
info "Step 6/8 - Updating system and installing prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget perl tar ca-certificates gnupg lsb-release

# Disable AppArmor profiles that conflict with cPanel (optional but recommended)
if systemctl is-active --quiet apparmor; then
  warn "Disabling AppArmor (recommended for cPanel on Ubuntu)..."
  systemctl stop apparmor
  systemctl disable apparmor
fi

# Disable UFW so cPanel can manage firewall rules (CSF is installed by default)
if command -v ufw >/dev/null 2>&1; then
  ufw disable || true
fi

log "System prepared."

# ---------- Step 7: Download & run cPanel installer ----------
info "Step 7/8 - Downloading and running cPanel installer..."
warn "This step takes 30-60 minutes. DO NOT interrupt."
warn "The installer will automatically request a 1 Monthly Cpanel license."

if [ -f /usr/local/cpanel/cpanel ]; then
  log "cPanel already installed. Skipping installation, refreshing license only."
else
  cd /home
  wget -N https://securedownloads.cpanel.net/latest || \
      err "Failed to download cPanel installer."
  # Run installer - it auto-detects Ubuntu and requests trial license
  sh latest
fi

# ---------- Step 8: Activate / verify the free trial license ----------
info "Step 8/8 - Activating cPanel server license..."
sleep 3

if [ -x /usr/local/cpanel/cpkeyclt ]; then
  /usr/local/cpanel/cpkeyclt
else
  err "cpkeyclt not found. Installation may have failed."
fi

# Verify license status
LICENSE_CHECK=$(/usr/local/cpanel/cpkeyclt 2>&1)
if echo "$LICENSE_CHECK" | grep -qi "update succeeded\|success"; then
  SERVER_IP=$(curl -s https://myip.cpanel.net || hostname -I | awk '{print $1}')
  echo ""
  echo -e "${GREEN}=====================================================${NC}"
  echo -e "${GREEN}   ✅ cPanel License activated successfully!      ${NC}"
  echo -e "${GREEN}=====================================================${NC}"
  echo -e "  🌐 WHM URL     : ${YELLOW}https://${SERVER_IP}:2087${NC}"
  echo -e "  👤 Username    : ${YELLOW}root${NC}"
  echo -e "  🔑 Password    : ${YELLOW}${NC}"
  echo -e "  📅 Trial length: ${YELLOW}15 days${NC}"
  echo -e "  💡 Convert to paid: ${YELLOW}https://sys.llc${NC}"
  echo -e "${GREEN}=====================================================${NC}"
else
  warn "License activation may have failed. Output:"
  echo "$LICENSE_CHECK"
  echo ""
  echo "Manual troubleshooting:"
  echo "  1. Email Support securenotic@gmail.com"
  echo "  2. Website Discus   https://sys.llc"
  echo "  3. Re-run Problem:              /usr/local/cpanel/cpkeyclt"
fi

exit 0
