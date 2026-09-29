#!/usr/bin/env bash
#
# ==============================================================================
#  cPanel & WHM Free Trial License — Universal VPS Installer
# ==============================================================================
#
#  This script automates the installation of cPanel & WHM on a supported
#  Linux VPS and automatically requests/activates the 15-day free trial
#  license from cPanel's license servers.
#
#  IMPORTANT — READ FIRST:
#  cPanel & WHM is officially supported ONLY on 64-bit, minimal installs of:
#     - AlmaLinux 8 / 9
#     - Rocky Linux 8 / 9
#     - CloudLinux 8 / 9
#     - RHEL 8 / 9  (with active subscription)
#  It is NOT supported on Ubuntu, Debian, Fedora, Arch, Windows, etc.
#  This script will detect your OS, warn you if it is unsupported, and
#  refuse to run the destructive installation steps on incompatible systems
#  (you may force it with --force, at your own risk — it will still fail
#  when the upstream cPanel installer performs its own OS check).
#
#  USAGE:
#     sudo bash install-cpanel-trial.sh [options]
#
#  OPTIONS:
#     --hostname <fqdn>     Set the server hostname before installing
#     --skip-checks         Skip RAM/disk/CPU pre-flight checks
#     --no-firewall-disable Do not disable firewalld/NetworkManager
#     --force               Attempt install even on an unsupported OS
#     --yes, -y             Non-interactive mode (auto-confirm prompts)
#     --help, -h            Show usage information
#
#  WHAT THIS SCRIPT DOES:
#     1. Verifies you are root and gathers system information
#     2. Detects the OS/distro and validates cPanel compatibility
#     3. Checks minimum hardware requirements (CPU, RAM, disk)
#     4. Optionally sets a fully-qualified hostname
#     5. Disables conflicting services (NetworkManager/firewalld) if present
#     6. Installs prerequisites (perl, curl, tar)
#     7. Downloads and runs the official cPanel installer
#        (https://securedownloads.cpanel.net/latest)
#     8. Runs cpkeyclt to request/activate the free trial license
#     9. Verifies the license and prints login details
#
#  LICENSE NOTE:
#  New cPanel & WHM installations automatically receive an evaluation
#  (trial) license valid for a limited number of days (historically up to
#  15 days, subject to change by cPanel L.L.C.). No account or payment
#  info is required to obtain it — it is issued automatically to your
#  server's public IP by cPanel's licensing servers as long as port 80/443
#  outbound access is available. After the trial period you must purchase
#  a license to keep using the software.
#
# ==============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# Globals & defaults
# ---------------------------------------------------------------------------
SCRIPT_VERSION="1.0.0"
LOG_FILE="/var/log/cpanel-trial-install.log"
HOSTNAME_ARG=""
SKIP_CHECKS=0
DISABLE_FIREWALL=1
FORCE_INSTALL=0
ASSUME_YES=0
CPANEL_INSTALLER_URL="https://securedownloads.cpanel.net/latest"
MIN_RAM_MB=1536          # cPanel hard minimum ~1GB, recommend 2GB+
MIN_DISK_GB=20
MIN_CPU_MHZ=1000

# Colors
C_RESET="\033[0m"; C_RED="\033[1;31m"; C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"; C_BLUE="\033[1;34m"; C_CYAN="\033[1;36m"; C_BOLD="\033[1m"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()      { echo -e "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >/dev/null; }
info()     { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; log "[INFO] $*"; }
ok()       { echo -e "${C_GREEN}[ OK ]${C_RESET}  $*"; log "[OK] $*"; }
warn()     { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; log "[WARN] $*"; }
err()      { echo -e "${C_RED}[FAIL]${C_RESET}  $*"; log "[FAIL] $*"; }
step()     { echo -e "\n${C_CYAN}${C_BOLD}==> $*${C_RESET}"; log "== $* =="; }
die()      { err "$*"; exit 1; }

confirm() {
  local prompt="$1"
  if [ "$ASSUME_YES" -eq 1 ]; then return 0; fi
  read -r -p "$prompt [y/N]: " reply
  case "$reply" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) return 1 ;;
  esac
}

usage() {
  sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --hostname) HOSTNAME_ARG="$2"; shift 2 ;;
    --skip-checks) SKIP_CHECKS=1; shift ;;
    --no-firewall-disable) DISABLE_FIREWALL=0; shift ;;
    --force) FORCE_INSTALL=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --help|-h) usage ;;
    *) die "Unknown option: $1 (use --help for usage)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Pre-flight: root check
# ---------------------------------------------------------------------------
require_root() {
  step "Checking privileges"
  if [ "$(id -u)" -ne 0 ]; then
    die "This script must be run as root. Try: sudo bash $0"
  fi
  ok "Running as root."
}

# ---------------------------------------------------------------------------
# OS detection & compatibility check
# ---------------------------------------------------------------------------
detect_os() {
  step "Detecting operating system"
  if [ ! -f /etc/os-release ]; then
    die "Cannot detect OS: /etc/os-release not found."
  fi
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-unknown}"
  OS_MAJOR="${OS_VERSION%%.*}"
  ARCH="$(uname -m)"

  info "Detected: ${PRETTY_NAME:-$OS_ID $OS_VERSION} (${ARCH})"

  SUPPORTED=0
  case "$OS_ID" in
    almalinux|rocky|rhel|centos|cloudlinux)
      if [ "$OS_MAJOR" -ge 8 ] 2>/dev/null; then
        SUPPORTED=1
      fi
      ;;
    *) SUPPORTED=0 ;;
  esac

  if [ "$ARCH" != "x86_64" ]; then
    warn "Architecture is '$ARCH'. cPanel requires 64-bit x86_64 hardware."
    SUPPORTED=0
  fi

  if [ "$SUPPORTED" -eq 1 ]; then
    ok "This OS is officially supported by cPanel & WHM."
  else
    warn "This OS/version is NOT on cPanel's officially supported list."
    warn "Supported: AlmaLinux/Rocky/CloudLinux/RHEL 8 or 9, 64-bit."
    if [ "$FORCE_INSTALL" -eq 1 ]; then
      warn "Continuing anyway because --force was specified. This will likely fail."
    else
      die "Aborting. Re-run with --force to attempt anyway (not recommended), or provision a supported OS image."
    fi
  fi
}

# ---------------------------------------------------------------------------
# Hardware requirement checks
# ---------------------------------------------------------------------------
check_hardware() {
  step "Checking hardware requirements"
  if [ "$SKIP_CHECKS" -eq 1 ]; then
    warn "Skipping hardware checks (--skip-checks given)."
    return
  fi

  local mem_mb disk_gb cpu_mhz cpu_cores
  mem_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
  disk_gb=$(df -BG --output=avail /home 2>/dev/null | tail -1 | tr -dc '0-9')
  [ -z "$disk_gb" ] && disk_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  cpu_cores=$(nproc)
  cpu_mhz=$(lscpu 2>/dev/null | awk -F: '/CPU MHz/ {gsub(/ /,"",$2); printf "%d", $2}')
  [ -z "$cpu_mhz" ] && cpu_mhz=$MIN_CPU_MHZ

  info "RAM: ${mem_mb}MB | Free disk: ${disk_gb}GB | CPU cores: ${cpu_cores} | CPU speed: ${cpu_mhz}MHz"

  local fail=0
  if [ "$mem_mb" -lt "$MIN_RAM_MB" ]; then
    warn "RAM (${mem_mb}MB) is below the recommended minimum (${MIN_RAM_MB}MB)."
    fail=1
  fi
  if [ -n "$disk_gb" ] && [ "$disk_gb" -lt "$MIN_DISK_GB" ]; then
    warn "Free disk space (${disk_gb}GB) is below the recommended minimum (${MIN_DISK_GB}GB)."
    fail=1
  fi

  if [ "$fail" -eq 1 ]; then
    if ! confirm "Hardware is below recommended specs. Continue anyway?"; then
      die "Aborted due to insufficient hardware resources."
    fi
  else
    ok "Hardware meets recommended requirements."
  fi
}

# ---------------------------------------------------------------------------
# Hostname configuration
# ---------------------------------------------------------------------------
configure_hostname() {
  step "Configuring hostname"
  local current_hostname
  current_hostname=$(hostname -f 2>/dev/null || hostname)

  if [ -n "$HOSTNAME_ARG" ]; then
    hostnamectl set-hostname "$HOSTNAME_ARG"
    ok "Hostname set to $HOSTNAME_ARG"
    return
  fi

  if [[ "$current_hostname" != *.*.* ]] && [[ "$current_hostname" != *"."*"."* ]]; then
    warn "Current hostname '$current_hostname' does not look like a fully-qualified domain name (e.g. server.example.com)."
    if [ "$ASSUME_YES" -eq 0 ]; then
      read -r -p "Enter an FQDN hostname to use (leave blank to keep current): " new_host
      if [ -n "$new_host" ]; then
        hostnamectl set-hostname "$new_host"
        ok "Hostname set to $new_host"
      else
        warn "Keeping existing hostname. cPanel may prompt you again during setup."
      fi
    fi
  else
    ok "Current hostname '$current_hostname' looks like a valid FQDN."
  fi
}

# ---------------------------------------------------------------------------
# Disable conflicting services
# ---------------------------------------------------------------------------
disable_conflicts() {
  step "Disabling services that commonly conflict with cPanel"
  if [ "$DISABLE_FIREWALL" -eq 0 ]; then
    warn "Skipping service disable step (--no-firewall-disable given)."
    return
  fi

  if systemctl list-unit-files 2>/dev/null | grep -q '^NetworkManager'; then
    systemctl disable --now NetworkManager >/dev/null 2>&1 && ok "NetworkManager disabled." || warn "Could not disable NetworkManager."
  fi

  if systemctl list-unit-files 2>/dev/null | grep -q '^firewalld'; then
    systemctl disable --now firewalld >/dev/null 2>&1 && ok "firewalld disabled (WHM ships its own firewall/CSF options)." || warn "Could not disable firewalld."
  fi
}

# ---------------------------------------------------------------------------
# Install prerequisites
# ---------------------------------------------------------------------------
install_prereqs() {
  step "Installing prerequisites (perl, curl, tar, cronie)"
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y perl curl tar cronie >>"$LOG_FILE" 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y perl curl tar cronie >>"$LOG_FILE" 2>&1
  else
    die "No supported package manager (dnf/yum) found."
  fi
  systemctl enable --now crond >/dev/null 2>&1
  ok "Prerequisites installed."
}

# ---------------------------------------------------------------------------
# Run the official cPanel installer
# ---------------------------------------------------------------------------
run_cpanel_installer() {
  step "Downloading and running the official cPanel & WHM installer"
  info "Source: $CPANEL_INSTALLER_URL"
  info "This step can take 30-90+ minutes depending on your server and network speed."
  info "Progress output is also being logged to $LOG_FILE"

  mkdir -p /home
  cd /home || die "Could not cd into /home"

  if ! curl -sS -o latest -L "$CPANEL_INSTALLER_URL"; then
    die "Failed to download the cPanel installer. Check your internet connectivity/DNS."
  fi

  ok "Installer downloaded. Launching installation (this will take a while)..."
  # Run inside a screen session if available so it survives disconnects
  if command -v screen >/dev/null 2>&1; then
    info "Running installer inside a 'screen' session named cpanel_install."
    screen -dmS cpanel_install bash -c "sh /home/latest 2>&1 | tee -a $LOG_FILE"
    info "Installer launched in background screen session."
    info "Attach anytime with: screen -r cpanel_install"
    info "Waiting for installation to complete..."
    while screen -list 2>/dev/null | grep -q "cpanel_install"; do
      sleep 30
      echo -n "."
    done
    echo ""
  else
    sh /home/latest 2>&1 | tee -a "$LOG_FILE"
  fi

  if [ ! -x /usr/local/cpanel/cpkeyclt ]; then
    die "cPanel installation does not appear to have completed successfully (cpkeyclt not found). Check $LOG_FILE."
  fi
  ok "cPanel & WHM installation finished."
}

# ---------------------------------------------------------------------------
# Request / activate the free trial license
# ---------------------------------------------------------------------------
activate_trial_license() {
  step "Requesting / activating the cPanel free trial license"
  info "New installations are automatically eligible for a free evaluation license."
  info "Contacting cPanel license servers via /usr/local/cpanel/cpkeyclt ..."

  if /usr/local/cpanel/cpkeyclt >>"$LOG_FILE" 2>&1; then
    ok "License client executed successfully."
  else
    warn "cpkeyclt returned a non-zero exit code. Check $LOG_FILE for details."
  fi

  sleep 5

  local pub_ip
  pub_ip=$(curl -sS -4 https://ifconfig.co 2>/dev/null || curl -sS -4 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
  info "Server public IP detected as: ${pub_ip:-unknown}"
  info "You can verify license status any time at: http://verify.cpanel.net/?ip=${pub_ip:-}"

  if [ -f /usr/local/cpanel/cpanel.lisc ] || [ -f /usr/local/cpanel/license.dat ]; then
    ok "A license file was found on disk. Trial license appears to be installed."
  else
    warn "No license file detected yet. It may take a few minutes to propagate."
    warn "You can manually re-run: /usr/local/cpanel/cpkeyclt"
  fi
}

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
print_summary() {
  local ip host
  ip=$(hostname -I | awk '{print $1}')
  host=$(hostname -f 2>/dev/null || hostname)

  step "Installation Summary"
  echo -e "${C_GREEN}cPanel & WHM installation process is complete!${C_RESET}"
  echo ""
  echo -e "  ${C_BOLD}WHM (admin) login:${C_RESET}   https://${host}:2087   (or https://${ip}:2087)"
  echo -e "  ${C_BOLD}cPanel (user) login:${C_RESET} https://${host}:2083"
  echo -e "  ${C_BOLD}Username:${C_RESET}            root"
  echo -e "  ${C_BOLD}License check:${C_RESET}       http://verify.cpanel.net/?ip=${ip}"
  echo -e "  ${C_BOLD}Full log file:${C_RESET}       ${LOG_FILE}"
  echo ""
  echo -e "${C_YELLOW}Reminder:${C_RESET} the free trial license is time-limited (historically up to"
  echo -e "15 days). Purchase a license from https://store.cpanel.net before it expires"
  echo -e "to avoid service interruption."
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  touch "$LOG_FILE" 2>/dev/null || LOG_FILE="./cpanel-trial-install.log"
  echo -e "${C_BOLD}cPanel & WHM Free Trial Installer v${SCRIPT_VERSION}${C_RESET}"
  echo "Log: $LOG_FILE"

  require_root
  detect_os
  check_hardware
  configure_hostname
  disable_conflicts
  install_prereqs
  run_cpanel_installer
  activate_trial_license
  print_summary
}

main "$@"
