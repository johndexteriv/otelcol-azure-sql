#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=install/lib.sh
source "${SCRIPT_DIR}/lib.sh"

PURGE_CONFIG=0

usage() {
  cat <<'EOF'
Usage: sudo install/uninstall.sh [--purge-config]

By default, customer config and the locked service identity are preserved so a
later reinstall can reuse them. --purge-config permanently removes both.
EOF
}

while (($# > 0)); do
  case "$1" in
    --purge-config)
      PURGE_CONFIG=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1 (use --help)."
      ;;
  esac
done

require_root
command -v systemctl >/dev/null 2>&1 ||
  die "systemctl is required to uninstall the service safely."

if systemctl list-unit-files "$SERVICE_NAME.service" >/dev/null 2>&1 ||
  [[ -f $UNIT_PATH ]]; then
  log "Stopping and disabling $SERVICE_NAME"
  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
fi

rm -f -- "$UNIT_PATH" "$BINARY_PATH" "$DEBUG_HELPER_PATH" "$INSTALL_META_PATH"
systemctl daemon-reload
systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true

if ((PURGE_CONFIG == 1)); then
  [[ $INSTALL_DIR == "/etc/otelcol-azure-sql" ]] ||
    die "Internal safety check refused config purge."
  rm -rf -- "$INSTALL_DIR"

  if getent passwd "$SERVICE_USER" >/dev/null 2>&1; then
    userdel "$SERVICE_USER"
  fi
  if getent group "$SERVICE_GROUP" >/dev/null 2>&1; then
    groupdel "$SERVICE_GROUP"
  fi
  log "Removed service, binary, helper, config, and service identity."
else
  log "Removed service unit, binary, and debug helper."
  printf 'Preserved customer config in %s (use --purge-config to remove it).\n' "$INSTALL_DIR"
fi
