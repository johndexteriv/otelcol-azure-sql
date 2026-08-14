#!/usr/bin/env bash
# Build the pinned Azure SQL-enabled OpenTelemetry Collector distribution.

set -Eeuo pipefail
IFS=$'\n\t'

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
VERSION_FILE="${HERE}/versions.env"
TEMPLATE="${HERE}/builder-config.yaml"
PATCH_DIR="${HERE}/patches"
BUILD_DIR="${HERE}/.build"
CONTRIB_DIR="${BUILD_DIR}/opentelemetry-collector-contrib"
GENERATED_CONFIG="${BUILD_DIR}/builder-config.yaml"
GENERATED_SOURCE="${BUILD_DIR}/otelcol-src"
TOOLS_DIR="${BUILD_DIR}/tools"
DIST_DIR="${HERE}/dist"
FINAL_BINARY="${DIST_DIR}/otelcol-azure-sql"
CONTRIB_URL="https://github.com/open-telemetry/opentelemetry-collector-contrib.git"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

read_version() {
  local key="$1" value
  value="$(awk -F= -v key="$key" '$1 == key { print $2 }' "$VERSION_FILE")"
  [[ -n "$value" ]] || die "${key} is not set in ${VERSION_FILE}"
  printf '%s' "$value"
}

normalize_arch() {
  case "$1" in
    amd64 | x86_64) printf 'amd64' ;;
    arm64 | aarch64) printf 'arm64' ;;
    *) die "unsupported architecture: $1 (expected amd64 or arm64)" ;;
  esac
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

contrib_at_tag() {
  local head_commit tag_commit
  head_commit="$(git -C "$CONTRIB_DIR" rev-parse HEAD 2>/dev/null || true)"
  tag_commit="$(git -C "$CONTRIB_DIR" rev-parse "${CONTRIB_TAG}^{commit}" 2>/dev/null || true)"
  [[ -n "$head_commit" && "$head_commit" == "$tag_commit" ]]
}

[[ -f "$VERSION_FILE" ]] || die "missing ${VERSION_FILE}"
PINNED_OTEL_VERSION="$(read_version OTEL_VERSION)"
PINNED_GO_VERSION="$(read_version GO_VERSION)"
PINNED_CONTRIB_COMMIT="$(read_version CONTRIB_COMMIT)"
OTEL_VERSION="$PINNED_OTEL_VERSION"
GO_VERSION="$PINNED_GO_VERSION"
TARGET_OS="${TARGET_OS:-linux}"
TARGET_ARCH="$(normalize_arch "${TARGET_ARCH:-amd64}")"
CONTRIB_TAG="v${OTEL_VERSION}"

[[ "$OTEL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "OTEL_VERSION must be a semantic version without a leading v"
[[ "$GO_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] ||
  die "GO_VERSION must be a numeric Go version"
[[ "$TARGET_OS" == "linux" ]] || die "only static linux builds are supported"

for command_name in awk curl git go grep python3 tail; do
  need_cmd "$command_name"
done

mkdir -p "$BUILD_DIR" "$TOOLS_DIR" "$DIST_DIR"

printf '==> preparing contrib %s\n' "$CONTRIB_TAG"
if [[ -d "${CONTRIB_DIR}/.git" ]] &&
  [[ "$(git -C "$CONTRIB_DIR" remote get-url origin 2>/dev/null || true)" == "$CONTRIB_URL" ]] &&
  contrib_at_tag; then
  git -C "$CONTRIB_DIR" reset --hard "${CONTRIB_TAG}^{commit}" >/dev/null
  git -C "$CONTRIB_DIR" clean -ffdqx >/dev/null
else
  rm -rf "$CONTRIB_DIR"
  git clone \
    --depth 1 \
    --branch "$CONTRIB_TAG" \
    --single-branch \
    "$CONTRIB_URL" \
    "$CONTRIB_DIR"
fi

contrib_at_tag ||
  die "contrib checkout is not exactly ${CONTRIB_TAG}"
[[ "$(git -C "$CONTRIB_DIR" rev-parse HEAD)" == "$PINNED_CONTRIB_COMMIT" ]] ||
  die "contrib ${CONTRIB_TAG} no longer resolves to pinned commit ${PINNED_CONTRIB_COMMIT}"
[[ -z "$(git -C "$CONTRIB_DIR" status --short)" ]] ||
  die "contrib checkout was not reset to a pristine state"

printf '==> applying reviewed patches\n'
shopt -s nullglob
patches=("${PATCH_DIR}"/*.patch)
shopt -u nullglob
(( ${#patches[@]} > 0 )) || die "no patch files found in ${PATCH_DIR}"
for patch_file in "${patches[@]}"; do
  git -C "$CONTRIB_DIR" apply --check "$patch_file"
  git -C "$CONTRIB_DIR" apply "$patch_file"
  printf '    %s\n' "$(basename "$patch_file")"
done

grep -Fq 'DriverAzureSQL' "${CONTRIB_DIR}/internal/sqlquery/driver.go" ||
  die "azuresql validation patch is missing"
grep -Fq 'github.com/microsoft/go-mssqldb/azuread' \
  "${CONTRIB_DIR}/receiver/sqlqueryreceiver/internal/database_sql.go" ||
  die "azuread registration patch is missing"

printf '==> generating portable OCB manifest\n'
python3 - \
  "$TEMPLATE" \
  "$GENERATED_CONFIG" \
  "$CONTRIB_DIR" \
  "$GENERATED_SOURCE" \
  "$OTEL_VERSION" <<'PY'
import pathlib
import re
import sys

template_path, output_path, contrib_arg, source_arg, otel_version = sys.argv[1:]
contrib = pathlib.Path(contrib_arg).resolve()
generated_source = pathlib.Path(source_arg).resolve()
manifest = (contrib / "cmd/otelcontribcol/builder-config.yaml").read_text()


def component_version(module):
    match = re.search(
        rf"^\s*-\s+gomod:\s+{re.escape(module)}\s+(v[0-9]+\.[0-9]+\.[0-9]+)\s*$",
        manifest,
        re.MULTILINE,
    )
    if not match:
        raise SystemExit(f"could not resolve {module} from upstream manifest")
    return match.group(1)


beta_modules = [
    "go.opentelemetry.io/collector/processor/memorylimiterprocessor",
    "go.opentelemetry.io/collector/processor/batchprocessor",
    "go.opentelemetry.io/collector/exporter/otlphttpexporter",
    "go.opentelemetry.io/collector/exporter/debugexporter",
]
stable_modules = [
    "go.opentelemetry.io/collector/confmap/provider/envprovider",
    "go.opentelemetry.io/collector/confmap/provider/fileprovider",
]
beta_versions = {component_version(module) for module in beta_modules}
stable_versions = {component_version(module) for module in stable_modules}
if len(beta_versions) != 1 or len(stable_versions) != 1:
    raise SystemExit("upstream component versions are no longer aligned; review the template")

text = pathlib.Path(template_path).read_text()
replacements = {
    "__OUTPUT_PATH__": generated_source.as_posix(),
    "__DIST_VERSION__": otel_version,
    "__CONTRIB_VERSION__": f"v{otel_version}",
    "__BETA_VERSION__": beta_versions.pop(),
    "__STABLE_VERSION__": stable_versions.pop(),
    "__CONTRIB_ROOT__": contrib.as_posix(),
}
for placeholder, value in replacements.items():
    text = text.replace(placeholder, value)
if re.search(r"__[A-Z0-9_]+__", text):
    raise SystemExit("unresolved placeholder in generated builder manifest")

replace_re = re.compile(r"^replace\s+(\S+)\s+=>\s+(\S+)\s*$", re.MULTILINE)
queue = [
    pathlib.Path("receiver/sqlqueryreceiver"),
    pathlib.Path("processor/resourceprocessor"),
    pathlib.Path("extension/healthcheckextension"),
]
seen = set()
local_replaces = {}
while queue:
    relative = queue.pop()
    if relative in seen:
        continue
    seen.add(relative)
    go_mod = contrib / relative / "go.mod"
    if not go_mod.is_file():
        continue
    for module, target in replace_re.findall(go_mod.read_text()):
        if not target.startswith("."):
            continue
        absolute_target = (contrib / relative / target).resolve()
        try:
            child = absolute_target.relative_to(contrib)
        except ValueError:
            continue
        local_replaces[module] = absolute_target.as_posix()
        queue.append(child)

if not local_replaces:
    raise SystemExit("no local contrib replacements were discovered")
text += "\nreplaces:\n"
for module in sorted(local_replaces):
    text += f"  - {module} => {local_replaces[module]}\n"
pathlib.Path(output_path).write_text(text)
print(f"    generated {output_path} with {len(local_replaces)} local replacements")
PY

host_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$host_os" in
  darwin | linux) ;;
  *) die "unsupported build host operating system: ${host_os}" ;;
esac
host_arch="$(normalize_arch "$(uname -m)")"
ocb="${TOOLS_DIR}/ocb_${OTEL_VERSION}_${host_os}_${host_arch}"
ocb_url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/cmd%2Fbuilder%2Fv${OTEL_VERSION}/ocb_${OTEL_VERSION}_${host_os}_${host_arch}"
ocb_checksum_url="${ocb_url}.sha256"
ocb_checksum_file="${TOOLS_DIR}/ocb_${OTEL_VERSION}_${host_os}_${host_arch}.sha256"
ocb_checksum_key="OCB_SHA256_$(printf '%s_%s' "$host_os" "$host_arch" | tr '[:lower:]' '[:upper:]')"
PINNED_OCB_SHA256="$(read_version "$ocb_checksum_key")"

verify_ocb() {
  local actual
  [[ -x "$1" ]] || return 1
  actual="$(sha256_file "$1")"
  [[ "$actual" == "$PINNED_OCB_SHA256" ]] &&
    "$1" version 2>&1 | grep -Fq "$OTEL_VERSION"
}

printf '==> preparing OCB %s for %s/%s\n' "$OTEL_VERSION" "$host_os" "$host_arch"
curl \
  --fail \
  --location \
  --proto '=https' \
  --tlsv1.2 \
  --retry 3 \
  --retry-all-errors \
  --connect-timeout 15 \
  --max-time 60 \
  --output "$ocb_checksum_file" \
  "$ocb_checksum_url"
published_ocb_checksum="$(grep -Eo '[A-Fa-f0-9]{64}' "$ocb_checksum_file" |
  awk 'NR == 1 { print tolower($0) }')"
[[ "$published_ocb_checksum" == "$PINNED_OCB_SHA256" ]] ||
  die "published OCB checksum differs from pinned ${ocb_checksum_key}; review the release"
if ! verify_ocb "$ocb"; then
  rm -f "$ocb"
  temporary_ocb="$(mktemp "${TOOLS_DIR}/.ocb.XXXXXX")"
  trap 'rm -f "${temporary_ocb:-}"' EXIT
  curl \
    --fail \
    --location \
    --proto '=https' \
    --tlsv1.2 \
    --retry 3 \
    --retry-all-errors \
    --connect-timeout 15 \
    --max-time 300 \
    --output "$temporary_ocb" \
    "$ocb_url"
  chmod 0755 "$temporary_ocb"
  verify_ocb "$temporary_ocb" ||
    die "downloaded OCB failed checksum or version verification for ${OTEL_VERSION}"
  mv "$temporary_ocb" "$ocb"
  trap - EXIT
fi
"$ocb" version

printf '==> building static %s/%s collector\n' "$TARGET_OS" "$TARGET_ARCH"
rm -rf "$GENERATED_SOURCE"
export CGO_ENABLED=0
export GOOS="$TARGET_OS"
export GOARCH="$TARGET_ARCH"
export GOFLAGS="-trimpath -buildvcs=false"
export GOTOOLCHAIN="go${GO_VERSION}+auto"
export SOURCE_DATE_EPOCH
SOURCE_DATE_EPOCH="$(git -C "$CONTRIB_DIR" show -s --format=%ct HEAD)"

actual_go_version="$(go env GOVERSION)"
[[ "$actual_go_version" == "go${GO_VERSION}" ]] ||
  die "expected Go ${GO_VERSION}, got ${actual_go_version}"

build_log="${BUILD_DIR}/build-${TARGET_OS}-${TARGET_ARCH}.log"
if ! "$ocb" --config "$GENERATED_CONFIG" >"$build_log" 2>&1; then
  printf '%s\n' "OCB build failed; log follows:" >&2
  tail -n 200 "$build_log" >&2
  exit 1
fi

built_binary="${GENERATED_SOURCE}/otelcol-azure-sql"
[[ -f "$built_binary" ]] ||
  die "OCB succeeded but did not create ${built_binary}"
install -m 0755 "$built_binary" "$FINAL_BINARY"

printf '==> verifying collector binary\n'
grep -aFq 'azuresql' "$FINAL_BINARY" ||
  die "binary does not contain the azuresql driver name"
grep -aFq 'github.com/microsoft/go-mssqldb/azuread' "$FINAL_BINARY" ||
  die "binary does not contain the linked azuread package"
if command -v file >/dev/null 2>&1; then
  file_description="$(file -b "$FINAL_BINARY")"
  printf '    %s\n' "$file_description"
  [[ "$file_description" != *"dynamically linked"* ]] ||
    die "collector binary is dynamically linked"
fi

can_execute=false
if [[ "$(uname -s)" == "Linux" ]] &&
  [[ "$(normalize_arch "$(uname -m)")" == "$TARGET_ARCH" ]]; then
  can_execute=true
fi
if [[ "$can_execute" == true ]]; then
  version_output="$("$FINAL_BINARY" --version)"
  printf '    %s\n' "$version_output"
  grep -Fq "$OTEL_VERSION" <<<"$version_output" ||
    die "collector --version does not contain ${OTEL_VERSION}"
else
  grep -aFq "$OTEL_VERSION" "$FINAL_BINARY" ||
    die "cross-built binary does not contain version ${OTEL_VERSION}"
  printf '    --version execution skipped for cross-built linux/%s binary\n' "$TARGET_ARCH"
fi

printf '==> built %s\n' "$FINAL_BINARY"
printf '    sha256 %s\n' "$(sha256_file "$FINAL_BINARY")"
