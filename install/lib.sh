#!/usr/bin/env bash
# Shared constants are consumed by scripts that source this file.
# shellcheck disable=SC2034

readonly SERVICE_NAME="otelcol-azure-sql"
readonly SERVICE_USER="otelcol-azure-sql"
readonly SERVICE_GROUP="otelcol-azure-sql"
readonly INSTALL_DIR="/etc/otelcol-azure-sql"
readonly BINARY_PATH="/usr/local/bin/otelcol-azure-sql"
readonly DEBUG_HELPER_PATH="/usr/local/sbin/otelcol-azure-sql-debug"
readonly UNIT_PATH="/etc/systemd/system/otelcol-azure-sql.service"
readonly ENV_PATH="${INSTALL_DIR}/env"
readonly COLLECTOR_CONFIG_PATH="${INSTALL_DIR}/collector.yaml"
readonly QUERIES_CONFIG_PATH="${INSTALL_DIR}/queries.yaml"
readonly DEBUG_CONFIG_PATH="${INSTALL_DIR}/debug.yaml"
readonly INSTALL_META_PATH="${INSTALL_DIR}/install.meta"
readonly DEFAULT_OTEL_VERSION="0.158.0"
readonly DEFAULT_CUSTOM_RELEASE_REPOSITORY="johndexteriv/otelcol-azure-sql"
readonly HEALTH_URL="http://127.0.0.1:13133/healthz"
readonly INTERNAL_METRICS_URL="http://127.0.0.1:8888/metrics"

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

error() {
  printf '[ERROR] %s\n' "$*" >&2
}

die() {
  error "$*"
  exit 1
}

require_root() {
  if ((EUID != 0)); then
    die "This command must run as root (for example: sudo $0)."
  fi
}

trim_leading_whitespace() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  printf '%s' "$value"
}

trim_trailing_whitespace() {
  local value=$1
  value=${value%"${value##*[![:space:]]}"}
  printf '%s' "$value"
}

decode_double_quoted_value() {
  local input=$1
  local output=""
  local character next
  local index

  for ((index = 0; index < ${#input}; index++)); do
    character=${input:index:1}
    if [[ $character == \\ ]] && ((index + 1 < ${#input})); then
      next=${input:index+1:1}
      case "$next" in
        '"'|\\|'$'|'`')
          output+=$next
          ((index += 1))
          ;;
        *)
          output+=$'\\'
          ;;
      esac
    else
      output+=$character
    fi
  done

  printf '%s' "$output"
}

# Parse a conservative systemd EnvironmentFile-compatible subset without eval.
# Blank lines and leading #/; comments are accepted. Values may be unquoted,
# single quoted, or double quoted. Shell expansion and command execution never
# occur.
load_env_file() {
  local file=$1
  local export_values=${2:-1}
  local line key raw value trailing
  local line_number=0

  [[ -r $file ]] || {
    error "Environment file is not readable: $file"
    return 1
  }

  while IFS= read -r line || [[ -n $line ]]; do
    ((line_number += 1))
    line=${line%$'\r'}
    if [[ $line =~ ^[[:space:]]*$ || $line =~ ^[[:space:]]*[#\;] ]]; then
      continue
    fi
    if [[ ! $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      error "$file:$line_number is not a KEY=VALUE assignment."
      return 1
    fi

    key=${BASH_REMATCH[1]}
    raw=$(trim_leading_whitespace "${BASH_REMATCH[2]}")
    value=""

    if [[ $raw == \"* ]]; then
      if [[ ! $raw =~ ^\"(.*)\"([[:space:]]*)$ ]]; then
        error "$file:$line_number has an unterminated or trailing double-quoted value."
        return 1
      fi
      value=$(decode_double_quoted_value "${BASH_REMATCH[1]}")
    elif [[ $raw == \'* ]]; then
      if [[ ! $raw =~ ^\'([^\']*)\'([[:space:]]*)$ ]]; then
        error "$file:$line_number has an unterminated or trailing single-quoted value."
        return 1
      fi
      value=${BASH_REMATCH[1]}
    else
      trailing=$(trim_trailing_whitespace "$raw")
      if [[ $trailing == *\\ ]]; then
        error "$file:$line_number uses an unsupported multiline continuation."
        return 1
      fi
      value=$trailing
    fi

    printf -v "$key" '%s' "$value"
    if ((export_values == 1)); then
      export "${key?}"
    else
      export -n "${key?}"
    fi
  done <"$file"
}

validate_env_permissions() {
  local file=$1
  local expected_owner=${2:-}
  local mode owner

  [[ -f $file && ! -L $file ]] || {
    error "Environment file must be a regular file, not a symlink: $file"
    return 1
  }

  mode=$(stat -Lc '%a' -- "$file") || return 1
  if (((8#$mode & 077) != 0)); then
    error "Environment file $file is too permissive (mode $mode); use chmod 600."
    return 1
  fi
  if (((8#$mode & 0400) == 0)); then
    error "Environment file owner cannot read $file (mode $mode)."
    return 1
  fi

  if [[ -n $expected_owner ]]; then
    owner=$(stat -Lc '%U' -- "$file") || return 1
    if [[ $owner != "$expected_owner" ]]; then
      error "Environment file $file must be owned by $expected_owner, not $owner."
      return 1
    fi
  fi
}

reject_placeholders() {
  local file
  for file in "$@"; do
    [[ -f $file ]] || {
      error "Required file does not exist: $file"
      return 1
    }
    if awk '!/^[[:space:]]*[#;]/ { print }' "$file" |
      grep -Eq '<[A-Z][A-Z0-9_/-]*>'; then
      error "Unresolved <NAME> placeholder found in an active value in $file."
      return 1
    fi
  done
}

active_drivers() {
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*driver:[[:space:]]*/ {
      value=$0
      sub(/^[[:space:]]*driver:[[:space:]]*/, "", value)
      sub(/[[:space:]]+#.*$/, "", value)
      gsub(/["'\''[:space:]]/, "", value)
      if (value != "") print value
    }
  ' "$@" | sort -u
}

detect_config_profile() {
  local drivers
  drivers=$(active_drivers "$@")
  if grep -qx 'azuresql' <<<"$drivers" && ! grep -qx 'sqlserver' <<<"$drivers"; then
    printf '%s\n' "managed-identity"
  elif grep -qx 'sqlserver' <<<"$drivers" && ! grep -qx 'azuresql' <<<"$drivers"; then
    printf '%s\n' "sql-auth"
  else
    return 1
  fi
}

validate_profile_compatibility() {
  local profile=$1
  shift
  local drivers expected unexpected
  drivers=$(active_drivers "$@")

  case "$profile" in
    managed-identity)
      expected="azuresql"
      unexpected="sqlserver"
      ;;
    sql-auth)
      expected="sqlserver"
      unexpected="azuresql"
      ;;
    *)
      error "Unknown profile: $profile"
      return 1
      ;;
  esac

  if ! grep -qx "$expected" <<<"$drivers"; then
    error "Profile $profile requires an active 'driver: $expected' receiver."
    return 1
  fi
  if grep -qx "$unexpected" <<<"$drivers"; then
    error "Profile $profile is incompatible with active 'driver: $unexpected'."
    return 1
  fi
  if grep -Evqx "$expected" <<<"$drivers"; then
    error "Profile $profile found unsupported active driver(s): $(tr '\n' ' ' <<<"$drivers")"
    return 1
  fi
}

referenced_env_vars() {
  awk '!/^[[:space:]]*#/ { print }' "$@" 2>/dev/null |
    grep -Eo '\$\{env:[A-Za-z_][A-Za-z0-9_]*\}' |
    sed -E 's/^\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}$/\1/' |
    sort -u
}

validate_required_env() {
  local profile=$1
  shift
  local variable
  local -a missing=()

  while IFS= read -r variable; do
    [[ -n $variable ]] || continue
    if [[ -z ${!variable:-} ]]; then
      missing+=("$variable")
    fi
  done < <(referenced_env_vars "$@")

  if [[ $profile == "sql-auth" ]]; then
    [[ -n ${SQL_USERNAME:-} ]] || missing+=("SQL_USERNAME")
    [[ -n ${SQL_PASSWORD:-} ]] || missing+=("SQL_PASSWORD")
  fi

  if ((${#missing[@]} > 0)); then
    error "Required environment variable(s) are empty or missing: $(printf '%s ' "${missing[@]}")"
    return 1
  fi
}

sha256_file() {
  local file=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print tolower($1)}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print tolower($1)}'
  else
    return 1
  fi
}
