#!/usr/bin/env bash
set -uo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=install/lib.sh
source "${SCRIPT_DIR}/lib.sh"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
ENV_LOADED=0
PROFILE=""
declare -a FQDNS=()

pass() {
  ((PASS_COUNT += 1))
  printf '[PASS] %s\n' "$*"
}

diagnostic_warn() {
  ((WARN_COUNT += 1))
  printf '[WARN] %s\n' "$*"
}

fail() {
  ((FAIL_COUNT += 1))
  printf '[FAIL] %s\n' "$*"
}

heading() {
  printf '\n== %s ==\n' "$*"
}

valid_fqdn() {
  local host=$1
  [[ ${#host} -le 253 &&
    $host =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

discover_fqdns() {
  local line remainder variable value host
  local env_marker="\${env:"
  local datasource_regex='sqlserver://([^/:?"]+)'
  local -A seen=()
  local -a candidates=()

  while IFS= read -r line; do
    remainder=$line
    while [[ $remainder =~ \$\{env:([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
      variable=${BASH_REMATCH[1]}
      value=${!variable:-}
      IFS=', ' read -r -a candidates <<<"$value"
      for host in "${candidates[@]}"; do
        host=${host#tcp:}
        host=${host#http://}
        host=${host#https://}
        host=${host%%/*}
        host=${host%%:*}
        [[ -n $host ]] && seen["$host"]=1
      done
      remainder=${remainder#*"${BASH_REMATCH[0]}"}
    done

    if [[ $line != *"$env_marker"* &&
      $line =~ ^[[:space:]]*host:[[:space:]]*[\"\']?([^[:space:]\"\'#]+) ]]; then
      host=${BASH_REMATCH[1]}
      host=${host%%:*}
      seen["$host"]=1
    elif [[ $line =~ $datasource_regex ]]; then
      seen["${BASH_REMATCH[1]}"]=1
    fi
  done < <(
    awk '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*(host|datasource):[[:space:]]*/ { print }
    ' "$COLLECTOR_CONFIG_PATH" "$QUERIES_CONFIG_PATH" 2>/dev/null
  )

  if [[ -n ${SQL_SERVER_FQDN:-} ]]; then
    IFS=', ' read -r -a candidates <<<"$SQL_SERVER_FQDN"
    for host in "${candidates[@]}"; do
      host=${host#tcp:}
      host=${host%%:*}
      seen["$host"]=1
    done
  fi

  if ((${#seen[@]} > 0)); then
    mapfile -t FQDNS < <(printf '%s\n' "${!seen[@]}" | sort -u)
  fi
}

discover_first_database() {
  local value
  value=$(awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*database:[[:space:]]*/ {
      sub(/^[[:space:]]*database:[[:space:]]*/, "")
      gsub(/["'\''[:space:]]/, "")
      print
      exit
    }
    /database=[^&"]+/ {
      match($0, /database=[^&"]+/)
      value = substr($0, RSTART + 9, RLENGTH - 9)
      print value
      exit
    }
  ' "$QUERIES_CONFIG_PATH" 2>/dev/null)
  printf '%s\n' "${value:-master}"
}

sum_metric() {
  local payload=$1
  local metric_regex=$2
  awk -v metric="$metric_regex" '
    $0 !~ /^#/ && $1 ~ ("^(" metric ")(\\{|$)") {
      total += $NF
      found = 1
    }
    END {
      if (found) printf "%.0f\n", total
    }
  ' <<<"$payload"
}

heading "Installation and profile"

if [[ -f $UNIT_PATH ]]; then
  pass "systemd unit file exists at $UNIT_PATH."
  if grep -Fq "EnvironmentFile=${ENV_PATH}" "$UNIT_PATH"; then
    pass "systemd unit uses the protected installed environment file."
  else
    fail "systemd unit does not reference ${ENV_PATH}."
  fi
  if grep -Fq -- "--config=file:${COLLECTOR_CONFIG_PATH}" "$UNIT_PATH" &&
    grep -Fq -- "--config=file:${QUERIES_CONFIG_PATH}" "$UNIT_PATH"; then
    pass "systemd ExecStart loads both production config files."
  else
    fail "systemd ExecStart does not load both production config files."
  fi
else
  fail "systemd unit file is missing at $UNIT_PATH."
fi

if [[ -x $BINARY_PATH ]]; then
  pass "Collector binary is installed and executable."
else
  fail "Collector binary is missing or not executable at $BINARY_PATH."
fi

missing_configs=0
for file in "$COLLECTOR_CONFIG_PATH" "$QUERIES_CONFIG_PATH" "$DEBUG_CONFIG_PATH"; do
  if [[ ! -f $file || -L $file ]]; then
    fail "Required installed config is missing or is a symlink: $file"
    missing_configs=1
  fi
done
((missing_configs == 0)) && pass "Production and debug config files are present."

if [[ -f $COLLECTOR_CONFIG_PATH && -f $QUERIES_CONFIG_PATH ]]; then
  if PROFILE=$(detect_config_profile "$COLLECTOR_CONFIG_PATH" "$QUERIES_CONFIG_PATH"); then
    pass "Detected $PROFILE profile from active SQL receiver drivers."
  else
    fail "Could not determine one profile from active driver values."
  fi
fi

if [[ -r $INSTALL_META_PATH && -n $PROFILE ]]; then
  declared_profile=$(awk -F= '$1 == "PROFILE" { print $2; exit }' "$INSTALL_META_PATH")
  if [[ -n $declared_profile && $declared_profile != "$PROFILE" ]]; then
    fail "Install metadata profile ($declared_profile) does not match active config ($PROFILE)."
  elif [[ -n $declared_profile ]]; then
    pass "Install metadata agrees with the active profile."
  fi
fi

if [[ ! -e $ENV_PATH ]]; then
  fail "Environment file is missing at $ENV_PATH."
elif [[ ! -r $ENV_PATH ]]; then
  diagnostic_warn "Environment file exists but is unreadable. Re-run with sudo for complete diagnostics."
else
  if validate_env_permissions "$ENV_PATH" root; then
    pass "Environment file is root-owned with private permissions."
  else
    fail "Environment file ownership or permissions are unsafe."
  fi
  if reject_placeholders "$ENV_PATH" "$COLLECTOR_CONFIG_PATH" "$QUERIES_CONFIG_PATH" "$DEBUG_CONFIG_PATH"; then
    pass "No unresolved <PLACEHOLDER> values were found."
  else
    fail "Resolve placeholders in the installed environment/config."
  fi
  if load_env_file "$ENV_PATH" 0; then
    ENV_LOADED=1
    pass "Environment file parsed without executing shell content."
  else
    fail "Environment file syntax is invalid."
  fi
fi

if [[ -n $PROFILE && $missing_configs -eq 0 ]]; then
  if validate_profile_compatibility "$PROFILE" "$COLLECTOR_CONFIG_PATH" "$QUERIES_CONFIG_PATH"; then
    pass "Active receiver drivers are compatible with $PROFILE."
  else
    fail "Active receiver drivers are incompatible with $PROFILE."
  fi
fi

if ((ENV_LOADED == 1)) && [[ -n $PROFILE ]] && ((missing_configs == 0)); then
  if validate_required_env "$PROFILE" "$COLLECTOR_CONFIG_PATH" "$QUERIES_CONFIG_PATH"; then
    pass "All config-referenced environment variables are non-empty."
  else
    fail "One or more required environment variables are missing."
  fi
  if [[ $PROFILE == "sql-auth" ]]; then
    if [[ -n ${SQL_USERNAME:-} && -n ${SQL_PASSWORD:-} ]]; then
      pass "SQL-auth username and password are present (values not printed)."
    else
      fail "SQL-auth requires non-empty SQL_USERNAME and SQL_PASSWORD."
    fi
  fi
fi

heading "Identity"

if [[ $PROFILE == "managed-identity" ]]; then
  client_id=${AZURE_MANAGED_IDENTITY_CLIENT_ID:-}
  imds_url='http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fdatabase.windows.net%2F'
  if [[ -n $client_id ]]; then
    if [[ $client_id =~ ^[A-Fa-f0-9-]{32,36}$ ]]; then
      imds_url+="&client_id=${client_id}"
    else
      fail "Configured user-assigned managed identity client ID is not a valid GUID."
      imds_url=""
    fi
  fi

  if [[ -n $imds_url ]]; then
    imds_response=$(curl --noproxy '*' --silent --show-error --fail --max-time 5 \
      --header 'Metadata: true' "$imds_url" 2>/dev/null) || imds_response=""
    if grep -Eq '"access_token"[[:space:]]*:[[:space:]]*"[^"]+"' <<<"$imds_response"; then
      if [[ -n $client_id ]]; then
        pass "Azure IMDS returned a database token for the configured user-assigned identity."
      else
        pass "Azure IMDS returned a database token for the VM managed identity."
      fi
    else
      fail "Azure IMDS did not return a database access token."
    fi
    unset imds_response
  fi
elif [[ $PROFILE == "sql-auth" ]]; then
  pass "SQL-auth profile does not require an IMDS token."
else
  diagnostic_warn "Skipping identity checks because the profile is unknown."
fi

heading "Azure SQL network path"

if ((ENV_LOADED == 1)) && ((missing_configs == 0)); then
  discover_fqdns
fi

if ((${#FQDNS[@]} == 0)); then
  fail "No Azure SQL FQDN could be resolved from active query config."
else
  for fqdn in "${FQDNS[@]}"; do
    if ! valid_fqdn "$fqdn"; then
      fail "Configured SQL host is not a valid FQDN: $fqdn"
      continue
    fi
    if getent ahosts "$fqdn" >/dev/null 2>&1; then
      pass "DNS resolves $fqdn."
    else
      fail "DNS does not resolve $fqdn."
    fi
    if nc -z -w 5 "$fqdn" 1433 >/dev/null 2>&1; then
      pass "TCP connectivity to $fqdn:1433 succeeded."
    else
      fail "TCP connectivity to $fqdn:1433 failed."
    fi
  done
fi

heading "Optional direct SQL query"

SQLCMD_BIN=$(command -v sqlcmd 2>/dev/null || command -v go-sqlcmd 2>/dev/null || true)
if [[ -z $SQLCMD_BIN ]]; then
  diagnostic_warn "Go sqlcmd is not installed; direct identity/query check skipped (no ODBC package was installed)."
else
  SQLCMD_HELP=$("$SQLCMD_BIN" -? 2>&1 || true)
  if ! grep -q -- '--authentication-method' <<<"$SQLCMD_HELP"; then
    diagnostic_warn "Installed sqlcmd is not recognized as Go sqlcmd; it was not executed and no ODBC dependency was added."
  elif ((${#FQDNS[@]} == 0)) || [[ -z $PROFILE ]]; then
    diagnostic_warn "Go sqlcmd is available, but host/profile discovery failed."
  else
    sql_database=${SQL_DATABASE:-$(discover_first_database)}
    query='SET NOCOUNT ON; SELECT DB_NAME() AS database_name;'
    if [[ $PROFILE == "managed-identity" ]]; then
      declare -a identity_args=(--authentication-method ActiveDirectoryManagedIdentity)
      if [[ -n ${client_id:-} ]]; then
        identity_args+=(-U "$client_id")
      fi
      if "$SQLCMD_BIN" -S "${FQDNS[0]}" -d "$sql_database" \
        "${identity_args[@]}" -Q "$query" >/dev/null 2>&1; then
        pass "Go sqlcmd connected with managed identity and completed a basic query."
      else
        fail "Go sqlcmd managed-identity query failed."
      fi
    elif [[ -n ${SQL_USERNAME:-} && -n ${SQL_PASSWORD:-} ]]; then
      if SQLCMDUSER="$SQL_USERNAME" SQLCMDPASSWORD="$SQL_PASSWORD" \
        "$SQLCMD_BIN" -S "${FQDNS[0]}" -d "$sql_database" \
        -Q "$query" >/dev/null 2>&1; then
        pass "Go sqlcmd connected with SQL auth and completed a basic query."
      else
        fail "Go sqlcmd SQL-auth query failed (credentials were not printed or passed as arguments)."
      fi
    else
      fail "Go sqlcmd SQL-auth query skipped because credentials are absent."
    fi
  fi
fi

heading "Collector and systemd"

if ((ENV_LOADED == 1)) && [[ -x $BINARY_PATH ]] && ((missing_configs == 0)); then
  if (
    load_env_file "$ENV_PATH"
    exec "$BINARY_PATH" validate \
      --config="file:${COLLECTOR_CONFIG_PATH}" \
      --config="file:${QUERIES_CONFIG_PATH}"
  ) >/dev/null 2>&1; then
    pass "Collector validates both production config files with the installed environment."
  else
    fail "Collector config validation failed with the installed binary/environment."
  fi
else
  diagnostic_warn "Collector validation skipped because a prerequisite failed."
fi

if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    pass "systemd service is enabled."
  else
    fail "systemd service is not enabled."
  fi
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    pass "systemd service is active."
  else
    fail "systemd service is not active."
  fi
else
  fail "systemctl is unavailable."
fi

if curl --fail --silent --show-error --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then
  pass "Collector health endpoint is ready at $HEALTH_URL."
else
  fail "Collector health endpoint is not ready at $HEALTH_URL."
fi

heading "Recent journal symptoms"

if command -v journalctl >/dev/null 2>&1; then
  journal_output=$(journalctl -u "$SERVICE_NAME" --since '-15 minutes' --no-pager 2>/dev/null) || journal_output=""
  if [[ -z $journal_output ]]; then
    diagnostic_warn "No readable service journal entries were found in the last 15 minutes."
  else
    symptoms=0
    if grep -Eiq 'unsupported driver|unknown type.*sql(query|_query)' <<<"$journal_output"; then
      fail "Journal shows a collector/profile driver mismatch."
      ((symptoms += 1))
    fi
    if grep -Eiq 'login failed|token.*(fail|error)|managed identity.*(fail|error)|authentication.*(fail|error)' <<<"$journal_output"; then
      fail "Journal shows an Azure SQL authentication or managed-identity symptom."
      ((symptoms += 1))
    fi
    if grep -Eiq 'no such host|name resolution|dial tcp.*(timeout|refused)|i/o timeout' <<<"$journal_output"; then
      fail "Journal shows a DNS or TCP connectivity symptom."
      ((symptoms += 1))
    fi
    if grep -Eiq 'invalid object name|permission was denied|does not have permission' <<<"$journal_output"; then
      fail "Journal shows a SQL object or permission symptom."
      ((symptoms += 1))
    fi
    if grep -Eiq '(export|otlp).*(401|403|unauthorized|forbidden)|sending queue is full' <<<"$journal_output"; then
      fail "Journal shows a groundcover export authentication/backpressure symptom."
      ((symptoms += 1))
    fi
    ((symptoms == 0)) && pass "No known SQL, identity, network, or exporter symptoms found in the recent journal."
  fi
  unset journal_output
else
  diagnostic_warn "journalctl is unavailable; symptom scan skipped."
fi

heading "Collector internal metric counters"

metrics_payload=$(curl --fail --silent --show-error --max-time 3 "$INTERNAL_METRICS_URL" 2>/dev/null) || metrics_payload=""
if [[ -z $metrics_payload ]]; then
  diagnostic_warn "Internal Prometheus endpoint is unavailable at $INTERNAL_METRICS_URL."
else
  accepted=$(sum_metric "$metrics_payload" '(otelcol_)?receiver_accepted_metric_points')
  refused=$(sum_metric "$metrics_payload" '(otelcol_)?receiver_refused_metric_points')
  sent=$(sum_metric "$metrics_payload" '(otelcol_)?exporter_sent_metric_points')
  send_failed=$(sum_metric "$metrics_payload" '(otelcol_)?exporter_send_failed_metric_points')

  if [[ -n $accepted ]]; then
    pass "Receiver accepted metric points: $accepted."
  else
    diagnostic_warn "Receiver accepted-point counter is not exposed."
  fi
  if [[ -n $sent && $sent != "0" ]]; then
    pass "Exporter sent metric points: $sent."
  elif [[ $sent == "0" ]]; then
    diagnostic_warn "Exporter sent-point counter is present but still zero."
  else
    diagnostic_warn "Exporter sent-point counter is not exposed."
  fi
  if [[ -n $refused && $refused != "0" ]]; then
    diagnostic_warn "Receiver refused metric points: $refused."
  fi
  if [[ -n $send_failed && $send_failed != "0" ]]; then
    diagnostic_warn "Exporter failed metric points: $send_failed."
  fi
fi
unset metrics_payload

heading "Exact next steps"

service_label=${GROUNDCOVER_SERVICE_NAME:-'<service from /etc/otelcol-azure-sql/env>'}
environment_label=${GROUNDCOVER_ENV_NAME:-'<environment from /etc/otelcol-azure-sql/env>'}
cat <<EOF
groundcover:
  1. Wait two SQL_COLLECTION_INTERVAL periods after the service becomes healthy.
  2. Open groundcover Metrics and query: activity_batch_pending
  3. Filter service_name = "${service_label}" and env = "${environment_label}".
  4. Group by db_name and confirm each configured database reports recent points.

Manual diagnostics (read-only):
  sudo ${SCRIPT_DIR}/validate.sh
  curl -fsS ${HEALTH_URL}
  curl -fsS ${INTERNAL_METRICS_URL} | grep -E 'receiver_(accepted|refused)_metric_points|exporter_(sent|send_failed)_metric_points'
  sudo journalctl -u ${SERVICE_NAME} --since '-15 minutes' --no-pager

One-off debug exporter (does not edit the production unit):
  sudo systemctl stop ${SERVICE_NAME}
  sudo ${DEBUG_HELPER_PATH}
  # Press Ctrl-C when done, then:
  sudo systemctl start ${SERVICE_NAME}
EOF

printf '\nSummary: %d pass, %d warning, %d fail.\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
((FAIL_COUNT == 0))
