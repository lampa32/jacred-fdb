#!/usr/bin/env bash
#
# JacRed-FDB installer
# Run from any account; will prompt for sudo if not root.
# Cron is added for the user who invoked sudo (or root if run as root).
#
set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly INSTALL_ROOT="/home/jacred"
readonly SYSTEMD_UNIT_PATH="/etc/systemd/system/jacred.service"
readonly DOTNET_INSTALL_DIR="/usr/share/dotnet"
readonly DOTNET_CHANNEL="9.0"
readonly PUBLISH_URL="https://github.com/lampa32/jacred-fdb/releases/latest/download/publish.zip"
readonly DB_URL="http://redb.cfhttp.top/latest.zip"
readonly CRON_SAVE_LINE='*/40 * * * * curl -s "http://127.0.0.1:9117/jsondb/save"'
readonly SAVE_URL="http://127.0.0.1:9117/jsondb/save"

CRON_USER="${SUDO_USER:-root}"
DOWNLOAD_DB=1
REMOVE=0
UPDATE=0
CLEANUP_PATHS=()

log_info() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

log_err() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
}

usage() {
  cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Install, update, or remove JacRed-FDB. Run as any user; sudo will be used when needed.

Options:
  --no-download-db    Do not download or unpack the initial database (install only)
  --update            Update app from latest release (saves DB, replaces files, restarts)
  --remove            Fully remove JacRed-FDB (service, cron, app directory)
  -h, --help          Show this help and exit

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME --no-download-db
  $SCRIPT_NAME --update
  $SCRIPT_NAME --remove

Run as a specific user (cron added/removed for that user):
  sudo -u myservice $SCRIPT_NAME
  sudo -u myservice $SCRIPT_NAME --update
  sudo -u myservice $SCRIPT_NAME --remove
EOF
}

cleanup() {
  local path
  for path in "${CLEANUP_PATHS[@]}"; do
    if [[ -e "$path" ]]; then
      log_info "Removing temporary path: $path"
      rm -rf "$path"
    fi
  done
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --no-download-db)
        DOWNLOAD_DB=0
        shift
        ;;
      --remove)
        REMOVE=1
        shift
        ;;
      --update)
        UPDATE=1
        shift
        ;;
      *)
        log_err "Unknown option: $1"
        usage >&2
        exit 1
        ;;
    esac
  done
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    exec sudo "$0" "$@"
  fi
}

remove_service() {
  if [[ ! -f "$SYSTEMD_UNIT_PATH" ]]; then
    log_info "Service unit not found, skipping"
    return 0
  fi
  log_info "Stopping and disabling jacred service..."
  systemctl stop jacred 2>/dev/null || true
  systemctl disable jacred 2>/dev/null || true
  rm -f "$SYSTEMD_UNIT_PATH"
  systemctl daemon-reload
  log_info "Service removed"
}

remove_cron() {
  local current filtered
  if [[ "$CRON_USER" == "root" ]]; then
    current="$(crontab -l 2>/dev/null || true)"
  else
    current="$(su "$CRON_USER" -c 'crontab -l 2>/dev/null' || true)"
  fi
  if [[ "$current" != *"$CRON_SAVE_LINE"* ]]; then
    log_info "Cron save line not found for $CRON_USER, skipping"
    return 0
  fi
  log_info "Removing cron save job for user: $CRON_USER"
  filtered="$(printf '%s\n' "$current" | grep -vF "$CRON_SAVE_LINE" || true)"
  if [[ "$CRON_USER" == "root" ]]; then
    printf '%s\n' "$filtered" | crontab -
  else
    printf '%s\n' "$filtered" | su "$CRON_USER" -c "crontab -"
  fi
  log_info "Cron removed"
}

remove_app() {
  if [[ ! -d "$INSTALL_ROOT" ]]; then
    log_info "Install directory not found: $INSTALL_ROOT, skipping"
    return 0
  fi
  log_info "Removing install directory: $INSTALL_ROOT"
  rm -rf "$INSTALL_ROOT"
  log_info "App directory removed"
}

do_remove() {
  log_info "Starting full removal..."
  remove_service
  remove_cron
  remove_app
  log_info "Removal complete."
}

do_update() {
  if [[ ! -d "$INSTALL_ROOT" ]]; then
    log_err "Install directory not found: $INSTALL_ROOT. Install first."
    exit 1
  fi
  log_info "Saving database..."
  curl -s "$SAVE_URL" || log_info "Save request sent (service may be stopped)"
  log_info "Stopping jacred service..."
  systemctl stop jacred 2>/dev/null || true
  log_info "Downloading latest release..."
  cd "$INSTALL_ROOT"
  wget -q "$PUBLISH_URL" -O publish.zip
  log_info "Unpacking..."
  unzip -oq publish.zip
  rm -f publish.zip
  log_info "Starting jacred service..."
  systemctl start jacred
  log_info "Update complete."
}

install_apt_packages() {
  log_info "Installing system packages (wget, unzip)..."
  apt update
  apt install -y --no-install-recommends wget unzip
}

install_dotnet() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  CLEANUP_PATHS+=("$tmpdir")

  log_info "Installing .NET ${DOTNET_CHANNEL}..."
  wget -q "https://dot.net/v1/dotnet-install.sh" -O "${tmpdir}/dotnet-install.sh"
  chmod 755 "${tmpdir}/dotnet-install.sh"
  "${tmpdir}/dotnet-install.sh" --channel "$DOTNET_CHANNEL" --install-dir "$DOTNET_INSTALL_DIR"

  if [[ ! -x "${DOTNET_INSTALL_DIR}/dotnet" ]]; then
    log_err ".NET binary not found after install"
    exit 1
  fi
  ln -sf "${DOTNET_INSTALL_DIR}/dotnet" /usr/bin/dotnet
  log_info ".NET installed successfully"
}

install_app() {
  log_info "Downloading and extracting application..."
  mkdir -p "$INSTALL_ROOT"
  cd "$INSTALL_ROOT"
  wget -q "$PUBLISH_URL" -O publish.zip
  unzip -oq publish.zip
  rm -f publish.zip
  log_info "Application installed to $INSTALL_ROOT"
}

install_systemd_unit() {
  log_info "Installing systemd unit: $SYSTEMD_UNIT_PATH"
  cat << EOF > "$SYSTEMD_UNIT_PATH"
[Unit]
Description=jacred
Wants=network.target
After=network.target
[Service]
WorkingDirectory=$INSTALL_ROOT
ExecStart=/usr/bin/dotnet JacRed.dll
Restart=always
[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$SYSTEMD_UNIT_PATH"
  systemctl daemon-reload
  systemctl enable jacred
}

install_cron() {
  local current
  if [[ "$CRON_USER" == "root" ]]; then
    current="$(crontab -l 2>/dev/null || true)"
  else
    current="$(su "$CRON_USER" -c 'crontab -l 2>/dev/null' || true)"
  fi
  if [[ "$current" == *"$CRON_SAVE_LINE"* ]]; then
    log_info "Cron save line already present for $CRON_USER, skipping"
    return 0
  fi
  log_info "Adding cron save job for user: $CRON_USER"
  if [[ "$CRON_USER" == "root" ]]; then
    (printf '%s\n' "$current"; echo "$CRON_SAVE_LINE") | crontab -
  else
    su "$CRON_USER" -c "(crontab -l 2>/dev/null || true; echo '$CRON_SAVE_LINE') | crontab -"
  fi
}

install_database() {
  if [[ "$DOWNLOAD_DB" -ne 1 ]]; then
    log_info "Skipping database download (--no-download-db)"
    return 0
  fi
  log_info "Downloading database..."
  cd "$INSTALL_ROOT"
  wget -q "$DB_URL" -O latest.zip
  log_info "Unpacking database..."
  unzip -oq latest.zip
  rm -f latest.zip
  log_info "Database installed"
}

start_service() {
  log_info "Starting jacred service..."
  systemctl start jacred
}

print_post_install() {
  cat << EOF

################################################################

Installation complete.

  - Edit config: $INSTALL_ROOT/init.conf
  - Restart:     systemctl restart jacred
  - Full crontab: crontab $INSTALL_ROOT/Data/crontab

################################################################

EOF
}

main() {
  trap cleanup EXIT
  require_root "$@"
  parse_args "$@"

  if [[ "$REMOVE" -eq 1 ]]; then
    do_remove
    return 0
  fi

  if [[ "$UPDATE" -eq 1 ]]; then
    do_update
    return 0
  fi

  log_info "Starting installation..."

  install_apt_packages
  install_dotnet
  install_app
  install_systemd_unit
  install_cron
  install_database
  start_service
  print_post_install
}

main "$@"
