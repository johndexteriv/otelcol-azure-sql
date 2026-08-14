#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=install/lib.sh
source "${SCRIPT_DIR}/lib.sh"
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)

PROFILE="managed-identity"
VERSION="$DEFAULT_OTEL_VERSION"
PROFILE_EXPLICIT=0
VERSION_EXPLICIT=0
REPLACE_CONFIG=0
LOCAL_BINARY=""
TMP_DIR=""
declare -a ATOMIC_TEMP_FILES=()

usage() {
  cat <<'EOF'
Usage: sudo install/install.sh [options]

Options:
  --profile managed-identity|sql-auth  Authentication profile (default: managed-identity)
  --version VERSION                    Collector release version (defaults from config/env)
  --binary PATH                        Install an already-built local binary
  --replace-config                     Replace installed config and env from config/
  -h, --help                           Show this help

Managed-identity release overrides:
  OTEL_AZURE_SQL_RELEASE_REPOSITORY    GitHub owner/repository
  OTEL_AZURE_SQL_CUSTOM_RELEASE_TAG    Release tag (default: vVERSION)
  OTEL_AZURE_SQL_CUSTOM_ARTIFACT       Tarball asset name
  OTEL_AZURE_SQL_CUSTOM_CHECKSUM_ASSET Checksum asset name
  OTEL_AZURE_SQL_CUSTOM_SHA256         Explicit checksum fallback

SQL-auth checksum fallback:
  OTELCOL_CONTRIB_SHA256               Explicit checksum if the official checksum asset is absent
EOF
}

cleanup() {
  local path
  for path in "${ATOMIC_TEMP_FILES[@]:-}"; do
    if [[ -n $path ]]; then
      rm -f -- "$path"
    fi
  done
  if [[ -n $TMP_DIR ]]; then
    rm -rf -- "$TMP_DIR"
  fi
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while (($# > 0)); do
  case "$1" in
    --profile)
      (($# >= 2)) || die "--profile requires a value."
      PROFILE=$2
      PROFILE_EXPLICIT=1
      shift 2
      ;;
    --profile=*)
      PROFILE=${1#*=}
      PROFILE_EXPLICIT=1
      shift
      ;;
    --version)
      (($# >= 2)) || die "--version requires a value."
      VERSION=${2#v}
      VERSION_EXPLICIT=1
      shift 2
      ;;
    --version=*)
      VERSION=${1#*=}
      VERSION=${VERSION#v}
      VERSION_EXPLICIT=1
      shift
      ;;
    --binary)
      (($# >= 2)) || die "--binary requires a path."
      LOCAL_BINARY=$2
      shift 2
      ;;
    --binary=*)
      LOCAL_BINARY=${1#*=}
      shift
      ;;
    --replace-config)
      REPLACE_CONFIG=1
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

[[ $PROFILE == "managed-identity" || $PROFILE == "sql-auth" ]] ||
  die "--profile must be managed-identity or sql-auth."
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] ||
  die "Invalid collector version: $VERSION"

require_root

[[ -f "${SCRIPT_DIR}/otelcol-azure-sql.service" ]] ||
  die "Installer package is incomplete: missing install/otelcol-azure-sql.service."

install_missing_dependencies() {
  local command package
  local -a missing=()
  local -a packages=()

  command -v systemctl >/dev/null 2>&1 ||
    die "systemctl is required; this installer supports existing systemd VMs only."
  [[ -d /run/systemd/system ]] ||
    die "systemd is not running as PID 1 on this VM."

  for command in curl tar getent nc stat install mktemp awk grep sed sort groupadd useradd usermod; do
    command -v "$command" >/dev/null 2>&1 || missing+=("$command")
  done
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    missing+=("sha256sum")
  fi

  ((${#missing[@]} == 0)) && return 0

  if [[ ! -r /etc/os-release ]] ||
    ! grep -Eq '^ID=(ubuntu|debian)$' /etc/os-release; then
    die "Missing required command(s): ${missing[*]}. Automatic package installation is limited to Ubuntu/Debian."
  fi

  for command in "${missing[@]}"; do
    case "$command" in
      curl) package="curl" ;;
      tar) package="tar" ;;
      getent) package="libc-bin" ;;
      nc) package="netcat-openbsd" ;;
      sha256sum|stat|install|mktemp) package="coreutils" ;;
      awk) package="gawk" ;;
      grep) package="grep" ;;
      sed) package="sed" ;;
      sort) package="coreutils" ;;
      groupadd|useradd|usermod) package="passwd" ;;
      *) die "No safe package mapping for missing command: $command" ;;
    esac
    if [[ ! " ${packages[*]} " =~ [[:space:]]${package}[[:space:]] ]]; then
      packages+=("$package")
    fi
  done

  log "Installing required OS package(s): ${packages[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends "${packages[@]}"

  for command in "${missing[@]}"; do
    if [[ $command == "sha256sum" ]]; then
      command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 ||
        die "No SHA-256 tool is available after package installation."
    else
      command -v "$command" >/dev/null 2>&1 ||
        die "Required command is still unavailable after package installation: $command"
    fi
  done
}

atomic_install_file() {
  local source=$1
  local target=$2
  local owner=$3
  local group=$4
  local mode=$5
  local temporary="${target}.tmp.$$"

  ATOMIC_TEMP_FILES+=("$temporary")
  install -o "$owner" -g "$group" -m "$mode" -- "$source" "$temporary"
  mv -fT -- "$temporary" "$target"
}

ensure_service_identity() {
  local nologin_shell="/usr/sbin/nologin"
  [[ -x $nologin_shell ]] || nologin_shell="/sbin/nologin"
  [[ -x $nologin_shell ]] || die "A nologin shell is required for the service account."

  if ! getent group "$SERVICE_GROUP" >/dev/null; then
    groupadd --system "$SERVICE_GROUP"
  fi

  if ! getent passwd "$SERVICE_USER" >/dev/null; then
    useradd --system \
      --gid "$SERVICE_GROUP" \
      --home-dir /nonexistent \
      --no-create-home \
      --shell "$nologin_shell" \
      "$SERVICE_USER"
  else
    usermod --lock --shell "$nologin_shell" "$SERVICE_USER"
  fi

  local primary_group
  primary_group=$(id -gn "$SERVICE_USER")
  [[ $primary_group == "$SERVICE_GROUP" ]] ||
    die "Existing user $SERVICE_USER has unexpected primary group $primary_group."
}

effective_path() {
  local name=$1
  local installed="${INSTALL_DIR}/${name}"
  local repository="${REPO_ROOT}/config/${name}"

  if [[ -e $installed && $REPLACE_CONFIG -eq 0 ]]; then
    [[ -f $installed && ! -L $installed ]] ||
      die "Installed customer file must be a regular file, not a symlink: $installed"
    printf '%s\n' "$installed"
  else
    [[ -f $repository && ! -L $repository ]] ||
      die "Missing regular source file ${repository}. Copy config/env.example to config/env and complete it."
    printf '%s\n' "$repository"
  fi
}

download() {
  local url=$1
  local destination=$2
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    --retry 3 --retry-delay 2 --output "$destination" "$url"
}

expected_checksum() {
  local checksum_file=$1
  local artifact=$2
  local explicit=$3
  local checksum=""

  if [[ -s $checksum_file ]]; then
    checksum=$(grep -F "$artifact" "$checksum_file" 2>/dev/null |
      grep -Eo '[A-Fa-f0-9]{64}' | awk 'NR == 1 { print tolower($0) }') || true
    if [[ -z $checksum ]]; then
      checksum=$(grep -Eo '^[A-Fa-f0-9]{64}([[:space:]]|$)' "$checksum_file" 2>/dev/null |
        awk 'NR == 1 { print tolower(substr($0, 1, 64)) }') || true
    fi
  fi

  if [[ -z $checksum && -n $explicit ]]; then
    checksum=${explicit,,}
  fi
  [[ $checksum =~ ^[a-f0-9]{64}$ ]] || return 1
  printf '%s\n' "$checksum"
}

extract_binary() {
  local archive=$1
  local expected_name=$2
  local output=$3
  local member type
  local -a members=()

  while IFS= read -r member; do
    [[ $member != /* && $member != ../* && $member != */../* && $member != */.. ]] ||
      die "Release archive contains an unsafe path."
    if [[ ${member##*/} == "$expected_name" ]]; then
      members+=("$member")
    fi
  done < <(tar -tzf "$archive")

  ((${#members[@]} == 1)) ||
    die "Release archive must contain exactly one $expected_name binary."
  member=${members[0]}
  type=$(tar -tvzf "$archive" "$member" | awk 'NR == 1 { print substr($1, 1, 1) }')
  [[ $type == "-" ]] || die "Archive member $member is not a regular file."
  tar -xOzf "$archive" "$member" >"$output"
  chmod 0755 "$output"
  [[ -s $output ]] || die "Extracted collector binary is empty."
}

download_collector() {
  local arch=$1
  local archive="${TMP_DIR}/collector.tar.gz"
  local checksum_file="${TMP_DIR}/checksums.txt"
  local binary="${TMP_DIR}/otelcol-azure-sql"
  local artifact checksum_asset repository tag prefix expected actual base_url binary_name version_output binary_version
  local explicit_checksum=""

  if [[ $PROFILE == "managed-identity" ]]; then
    repository=${OTEL_AZURE_SQL_RELEASE_REPOSITORY:-${COLLECTOR_RELEASE_REPOSITORY:-$DEFAULT_CUSTOM_RELEASE_REPOSITORY}}
    [[ $repository =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
      die "OTEL_AZURE_SQL_RELEASE_REPOSITORY must be a GitHub owner/repository."
    tag=${OTEL_AZURE_SQL_CUSTOM_RELEASE_TAG:-v${VERSION}}
    [[ $tag =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid custom release tag: $tag"
    prefix="otelcol-azure-sql"
    artifact=${OTEL_AZURE_SQL_CUSTOM_ARTIFACT:-${prefix}_${VERSION}_linux_${arch}.tar.gz}
    checksum_asset=${OTEL_AZURE_SQL_CUSTOM_CHECKSUM_ASSET:-SHA256SUMS}
    explicit_checksum=${OTEL_AZURE_SQL_CUSTOM_SHA256:-}
    binary_name=${OTEL_AZURE_SQL_CUSTOM_BINARY_NAME:-otelcol-azure-sql}
    base_url="https://github.com/${repository}/releases/download/${tag}"
  else
    repository="open-telemetry/opentelemetry-collector-releases"
    tag="v${VERSION}"
    prefix="otelcol-contrib"
    artifact="${prefix}_${VERSION}_linux_${arch}.tar.gz"
    checksum_asset="${artifact}.sha256"
    explicit_checksum=${OTELCOL_CONTRIB_SHA256:-}
    binary_name="otelcol-contrib"
    base_url="https://github.com/${repository}/releases/download/${tag}"
  fi

  [[ $artifact == "$(basename -- "$artifact")" && $artifact == *.tar.gz ]] ||
    die "Invalid collector artifact name: $artifact"
  [[ $checksum_asset == "$(basename -- "$checksum_asset")" ]] ||
    die "Invalid checksum asset name: $checksum_asset"
  [[ $binary_name =~ ^[A-Za-z0-9._-]+$ ]] ||
    die "Invalid archive binary name: $binary_name"

  log "Downloading ${repository} release ${tag} for linux/${arch}"
  download "${base_url}/${artifact}" "$archive" ||
    die "Could not download release artifact ${artifact}."

  if ! download "${base_url}/${checksum_asset}" "$checksum_file"; then
    rm -f -- "$checksum_file"
    if [[ -z $explicit_checksum ]]; then
      die "Checksum asset ${checksum_asset} is unavailable. Refusing an unverified install; configure the documented explicit SHA-256 fallback."
    fi
    warn "Published checksum asset is unavailable; using the explicitly configured SHA-256."
  fi

  expected=$(expected_checksum "$checksum_file" "$artifact" "$explicit_checksum") ||
    die "No valid SHA-256 for ${artifact} was found in ${checksum_asset} or the explicit fallback."
  actual=$(sha256_file "$archive") ||
    die "Unable to calculate SHA-256 for ${artifact}."
  [[ $actual == "$expected" ]] ||
    die "SHA-256 verification failed for ${artifact}."
  log "Verified SHA-256 for ${artifact}"

  extract_binary "$archive" "$binary_name" "$binary"
  version_output=$("$binary" --version 2>&1) ||
    die "Downloaded collector binary cannot execute on this VM."
  if [[ $PROFILE == "managed-identity" ]]; then
    binary_version=${VERSION%%-groundcover.*}
  else
    binary_version=$VERSION
  fi
  grep -Fq "$binary_version" <<<"$version_output" ||
    die "Downloaded collector does not report expected upstream version $binary_version."
}

install_missing_dependencies

case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) die "Unsupported Linux architecture: $(uname -m). Expected amd64 or arm64." ;;
esac
[[ $(uname -s) == "Linux" ]] || die "This installer supports Linux only."

TMP_DIR=$(mktemp -d /tmp/otelcol-azure-sql.XXXXXX)
chmod 0700 "$TMP_DIR"

EFFECTIVE_COLLECTOR=$(effective_path "collector.yaml")
EFFECTIVE_QUERIES=$(effective_path "queries.yaml")
EFFECTIVE_DEBUG=$(effective_path "debug.yaml")
EFFECTIVE_ENV=$(effective_path "env")

reject_placeholders \
  "$EFFECTIVE_ENV" "$EFFECTIVE_COLLECTOR" "$EFFECTIVE_QUERIES" "$EFFECTIVE_DEBUG" ||
  die "Resolve all placeholders before installing."

if [[ $EFFECTIVE_ENV == "$ENV_PATH" ]]; then
  validate_env_permissions "$EFFECTIVE_ENV" root ||
    die "Installed environment file failed its ownership/permission check."
else
  validate_env_permissions "$EFFECTIVE_ENV" ||
    die "Source config/env failed its permission check."
fi
load_env_file "$EFFECTIVE_ENV" 0 || die "Could not safely parse $EFFECTIVE_ENV."
if ((PROFILE_EXPLICIT == 0)) && [[ -n ${COLLECTOR_PROFILE:-} ]]; then
  PROFILE=$COLLECTOR_PROFILE
fi
if ((VERSION_EXPLICIT == 0)); then
  if [[ $PROFILE == "managed-identity" ]]; then
    VERSION=${CUSTOM_COLLECTOR_VERSION:-$DEFAULT_OTEL_VERSION}
  else
    VERSION=${STOCK_COLLECTOR_VERSION:-$DEFAULT_OTEL_VERSION}
  fi
fi
VERSION=${VERSION#v}
[[ $PROFILE == "managed-identity" || $PROFILE == "sql-auth" ]] ||
  die "COLLECTOR_PROFILE/--profile must be managed-identity or sql-auth."
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] ||
  die "Invalid collector version: $VERSION"
validate_profile_compatibility "$PROFILE" "$EFFECTIVE_COLLECTOR" "$EFFECTIVE_QUERIES" ||
  die "Collector configuration does not match --profile $PROFILE."
validate_required_env "$PROFILE" "$EFFECTIVE_COLLECTOR" "$EFFECTIVE_QUERIES" ||
  die "Complete config/env before installing."

COLLECTOR_BINARY="${TMP_DIR}/otelcol-azure-sql"
if [[ -n $LOCAL_BINARY ]]; then
  [[ -f $LOCAL_BINARY && ! -L $LOCAL_BINARY && -x $LOCAL_BINARY ]] ||
    die "--binary must reference a regular executable file: $LOCAL_BINARY"
  install -m 0755 -- "$LOCAL_BINARY" "$COLLECTOR_BINARY"
  expected_binary_version=${VERSION%%-groundcover.*}
  version_output=$("$COLLECTOR_BINARY" --version 2>&1) ||
    die "Local collector binary cannot execute on this VM."
  grep -Fq "$expected_binary_version" <<<"$version_output" ||
    die "Local collector does not report expected upstream version $expected_binary_version."
  if [[ $PROFILE == "managed-identity" ]]; then
    if ! grep -aFq 'azuresql' "$COLLECTOR_BINARY" ||
      ! grep -aFq 'github.com/microsoft/go-mssqldb/azuread' "$COLLECTOR_BINARY"; then
      die "Local binary does not contain the required Azure SQL managed-identity driver."
    fi
  fi
  log "Using verified local collector binary: $LOCAL_BINARY"
else
  download_collector "$ARCH"
fi
if ! (
  load_env_file "$EFFECTIVE_ENV"
  exec "$COLLECTOR_BINARY" validate \
    --config="file:${EFFECTIVE_COLLECTOR}" \
    --config="file:${EFFECTIVE_QUERIES}"
) >/dev/null 2>&1; then
  die "Collector validation failed with the selected binary/profile. Run install/validate.sh after correcting the config."
fi

ensure_service_identity
install -d -o root -g "$SERVICE_GROUP" -m 0750 "$INSTALL_DIR"

if [[ ! -f $COLLECTOR_CONFIG_PATH || $REPLACE_CONFIG -eq 1 ]]; then
  atomic_install_file "${REPO_ROOT}/config/collector.yaml" "$COLLECTOR_CONFIG_PATH" root "$SERVICE_GROUP" 0640
else
  log "Preserving existing $COLLECTOR_CONFIG_PATH"
fi
if [[ ! -f $QUERIES_CONFIG_PATH || $REPLACE_CONFIG -eq 1 ]]; then
  atomic_install_file "${REPO_ROOT}/config/queries.yaml" "$QUERIES_CONFIG_PATH" root "$SERVICE_GROUP" 0640
else
  log "Preserving existing $QUERIES_CONFIG_PATH"
fi
if [[ ! -f $DEBUG_CONFIG_PATH || $REPLACE_CONFIG -eq 1 ]]; then
  atomic_install_file "${REPO_ROOT}/config/debug.yaml" "$DEBUG_CONFIG_PATH" root "$SERVICE_GROUP" 0640
else
  log "Preserving existing $DEBUG_CONFIG_PATH"
fi
if [[ ! -f $ENV_PATH || $REPLACE_CONFIG -eq 1 ]]; then
  atomic_install_file "${REPO_ROOT}/config/env" "$ENV_PATH" root root 0600
else
  log "Preserving existing $ENV_PATH"
fi
chown root:"$SERVICE_GROUP" "$COLLECTOR_CONFIG_PATH" "$QUERIES_CONFIG_PATH" "$DEBUG_CONFIG_PATH"
chmod 0640 "$COLLECTOR_CONFIG_PATH" "$QUERIES_CONFIG_PATH" "$DEBUG_CONFIG_PATH"
chown root:root "$ENV_PATH"
chmod 0600 "$ENV_PATH"

atomic_install_file "$COLLECTOR_BINARY" "$BINARY_PATH" root root 0755
atomic_install_file "${SCRIPT_DIR}/otelcol-azure-sql.service" "$UNIT_PATH" root root 0644
atomic_install_file "${SCRIPT_DIR}/debug.sh" "$DEBUG_HELPER_PATH" root root 0755

cat >"${TMP_DIR}/install.meta" <<EOF
PROFILE=${PROFILE}
VERSION=${VERSION}
ARCH=${ARCH}
EOF
atomic_install_file "${TMP_DIR}/install.meta" "$INSTALL_META_PATH" root root 0644

validate_env_permissions "$ENV_PATH" root ||
  die "Installed environment file failed its ownership/permission check."
load_env_file "$ENV_PATH" 0 || die "Could not safely parse installed environment file."
if ! (
  load_env_file "$ENV_PATH"
  exec "$BINARY_PATH" validate \
    --config="file:${COLLECTOR_CONFIG_PATH}" \
    --config="file:${QUERIES_CONFIG_PATH}"
) >/dev/null 2>&1; then
  die "Installed collector configuration validation failed; the service was not restarted."
fi

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null
systemctl restart "$SERVICE_NAME"

HEALTHY=0
for _ in {1..30}; do
  if curl --fail --silent --show-error --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
    HEALTHY=1
    break
  fi
  sleep 1
done
if ((HEALTHY == 0)); then
  die "Service started but did not become healthy at ${HEALTH_URL}. Run: sudo install/validate.sh"
fi

log "Installation complete: ${SERVICE_NAME} (${PROFILE}, ${VERSION}, linux/${ARCH})"
cat <<EOF

Next steps:
  1. Run the read-only diagnostic ladder:
       sudo install/validate.sh
  2. Follow logs without exposing the environment file:
       sudo journalctl -u ${SERVICE_NAME} -f
  3. For a one-off debug run, first stop the production service, then run:
       sudo ${DEBUG_HELPER_PATH}
     Restart production afterward:
       sudo systemctl start ${SERVICE_NAME}
EOF
