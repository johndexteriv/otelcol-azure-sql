#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly SERVICE_NAME="otelcol-azure-sql"
readonly SERVICE_USER="otelcol-azure-sql"
readonly CONFIG_DIR="/etc/otelcol-azure-sql"
readonly BINARY="/usr/local/bin/otelcol-azure-sql"

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

if ((EUID != 0)); then
  die "Run this helper as root: sudo /usr/local/sbin/otelcol-azure-sql-debug"
fi
command -v systemd-run >/dev/null 2>&1 || die "systemd-run is required."

for file in \
  "$BINARY" \
  "${CONFIG_DIR}/env" \
  "${CONFIG_DIR}/collector.yaml" \
  "${CONFIG_DIR}/queries.yaml" \
  "${CONFIG_DIR}/debug.yaml"; do
  [[ -e $file ]] || die "Required installed file is missing: $file"
done

if systemctl is-active --quiet "$SERVICE_NAME"; then
  die "The production service is active and owns its health/metrics ports. Stop it explicitly first: sudo systemctl stop $SERVICE_NAME"
fi

printf '[WARN] Starting an interactive transient collector with debug.yaml.\n' >&2
printf '[WARN] Metric values may be written to this terminal. Press Ctrl-C to stop.\n' >&2

declare -a collect_option=()
if systemd-run --help 2>&1 | grep -q -- '--collect'; then
  collect_option=(--collect)
fi

UNIT_NAME="${SERVICE_NAME}-debug-${RANDOM}"
cleanup() {
  systemctl stop "$UNIT_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

systemd-run \
  --quiet \
  --wait \
  --pipe \
  "${collect_option[@]}" \
  --unit="$UNIT_NAME" \
  --service-type=exec \
  --uid="$SERVICE_USER" \
  --gid="$SERVICE_USER" \
  --property="EnvironmentFile=${CONFIG_DIR}/env" \
  --property="NoNewPrivileges=yes" \
  --property="PrivateTmp=yes" \
  --property="ProtectSystem=strict" \
  --property="ProtectHome=yes" \
  --property="RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6" \
  "$BINARY" \
  "--config=file:${CONFIG_DIR}/collector.yaml" \
  "--config=file:${CONFIG_DIR}/queries.yaml" \
  "--config=file:${CONFIG_DIR}/debug.yaml"
