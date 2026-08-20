#!/usr/bin/env bash
# Provision a throwaway Azure environment for testing otelcol-azure-sql:
# one resource group, one Linux VM with a system-assigned managed identity, one
# Azure SQL logical server, and two databases at different service objectives.
#
# This is a test harness, not a production deployment tool. It creates billable
# resources. Delete them with:
#   az group delete --name <resource-group> --yes --no-wait
#
# It reads no secrets from the repository. The SQL administrator password is
# generated at run time and written only to the file named by --credentials-out
# (mode 0600, default ./.azure-test-env, which .gitignore excludes).
#
# Reruns are safe: every step checks for an existing resource first.

set -Eeuo pipefail
IFS=$'\n\t'

RESOURCE_GROUP="rg-otelcol-azuresql-test"
LOCATION=""
VM_NAME="vm-otelcol-test"
VM_SIZE=""
SQL_SERVER=""
DB_FULL="db-full"
DB_FULL_SKU="S2"
DB_BACKUPS="db-backups"
DB_BACKUPS_SKU="S0"
ADMIN_USER="azureuser"
SQL_ADMIN_USER="sqladminuser"
CREDENTIALS_OUT="./.azure-test-env"
SEED_FIXTURE=0

# Regions are tried in order. Azure SQL frequently refuses new logical servers in
# a busy region with RegionDoesNotAllowProvisioning, and small VM sizes are not
# offered everywhere, so a single hard-coded region is not dependable.
CANDIDATE_LOCATIONS=(centralus eastus2 eastus westus3 westus2 southcentralus northcentralus)
# Only x86-64 sizes. The published collector releases are linux_amd64 and
# linux_arm64, but the rest of this harness assumes amd64.
CANDIDATE_SIZES=(Standard_B2s Standard_D2als_v7 Standard_D2as_v7 Standard_D2s_v7 Standard_F2als_v7)

log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: scripts/provision-azure-test-env.sh [options]

Options:
  --resource-group NAME   Resource group to create (default: rg-otelcol-azuresql-test)
  --location REGION       Pin a region instead of probing for an available one
  --vm-name NAME          VM name; also the managed identity display name
  --vm-size SIZE          Pin a VM size instead of probing
  --sql-server NAME       Logical server name (default: sql-otelcol-<random>)
  --db-full NAME          Database for the full query set (default: db-full, S2)
  --db-backups NAME       Restricted-tier database (default: db-backups, S0)
  --credentials-out PATH  Where to write generated values (default: ./.azure-test-env)
  --seed-fixture          Also apply sql/test-fixtures/seed-customer-schema.sql
                          and create the managed-identity SQL principals
  -h, --help              Show this help

Requires: az (logged in), and for --seed-fixture, Go sqlcmd 1.x.
EOF
}

while (($# > 0)); do
  case "$1" in
    --resource-group)  RESOURCE_GROUP=$2; shift 2 ;;
    --location)        LOCATION=$2; shift 2 ;;
    --vm-name)         VM_NAME=$2; shift 2 ;;
    --vm-size)         VM_SIZE=$2; shift 2 ;;
    --sql-server)      SQL_SERVER=$2; shift 2 ;;
    --db-full)         DB_FULL=$2; shift 2 ;;
    --db-backups)      DB_BACKUPS=$2; shift 2 ;;
    --credentials-out) CREDENTIALS_OUT=$2; shift 2 ;;
    --seed-fixture)    SEED_FIXTURE=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 die "Unknown option: $1 (use --help)." ;;
  esac
done

command -v az >/dev/null 2>&1 || die "The Azure CLI is required."
az account show >/dev/null 2>&1 ||
  die "Not signed in. Run: az login"
command -v openssl >/dev/null 2>&1 || die "openssl is required to generate a password."

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

if ((SEED_FIXTURE == 1)); then
  command -v sqlcmd >/dev/null 2>&1 ||
    die "--seed-fixture needs Go sqlcmd on PATH."
  sqlcmd --version 2>&1 | grep -Eq '^Version: 1\.' ||
    die "--seed-fixture needs Go sqlcmd 1.x; the ODBC sqlcmd rejects --authentication-method."
fi

[[ -n $SQL_SERVER ]] || SQL_SERVER="sql-otelcol-$(openssl rand -hex 3)"
# Avoid characters that need shell or SQL escaping, and never reuse the login
# name: Azure SQL rejects a password containing it.
SQL_ADMIN_PASSWORD="Ax7$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9')Qz9"

# ---------------------------------------------------------------- resource group
if az group show --name "$RESOURCE_GROUP" >/dev/null 2>&1; then
  EXISTING_LOCATION=$(az group show --name "$RESOURCE_GROUP" --query location -o tsv)
  log "Resource group $RESOURCE_GROUP already exists in $EXISTING_LOCATION."
  [[ -n $LOCATION ]] || LOCATION=$EXISTING_LOCATION
else
  # The group's own location is unconstrained, so create it in the first
  # candidate and let the SQL server decide the working region below.
  CREATE_IN=${LOCATION:-${CANDIDATE_LOCATIONS[0]}}
  log "Creating resource group $RESOURCE_GROUP in $CREATE_IN"
  az group create --name "$RESOURCE_GROUP" --location "$CREATE_IN" --output none
fi

# ------------------------------------------------------------------- sql server
if az sql server show -g "$RESOURCE_GROUP" -n "$SQL_SERVER" >/dev/null 2>&1; then
  LOCATION=$(az sql server show -g "$RESOURCE_GROUP" -n "$SQL_SERVER" --query location -o tsv)
  log "SQL server $SQL_SERVER already exists in $LOCATION; leaving its admin password unchanged."
  SQL_ADMIN_PASSWORD="<unchanged: not reset by this rerun>"
else
  if [[ -n $LOCATION ]]; then
    ATTEMPT_LOCATIONS=("$LOCATION")
  else
    ATTEMPT_LOCATIONS=("${CANDIDATE_LOCATIONS[@]}")
  fi
  CREATED=0
  for candidate in "${ATTEMPT_LOCATIONS[@]}"; do
    # A refused create still reserves the name, so use a fresh one each attempt.
    attempt_name=$SQL_SERVER
    ((CREATED == 0)) || break
    log "Attempting SQL server $attempt_name in $candidate"
    if az sql server create \
      -g "$RESOURCE_GROUP" -n "$attempt_name" -l "$candidate" \
      -u "$SQL_ADMIN_USER" -p "$SQL_ADMIN_PASSWORD" \
      --enable-public-network true --output none 2>/tmp/provision-sql-error.$$; then
      SQL_SERVER=$attempt_name
      LOCATION=$candidate
      CREATED=1
      log "Created SQL server $SQL_SERVER in $LOCATION"
    else
      warn "$candidate refused: $(grep -o 'Message: .*' /tmp/provision-sql-error.$$ | head -1)"
      SQL_SERVER="sql-otelcol-$(openssl rand -hex 3)"
    fi
    rm -f /tmp/provision-sql-error.$$
  done
  ((CREATED == 1)) ||
    die "No candidate region accepted a new Azure SQL logical server. Retry later or pass --location."
fi

SQL_FQDN=$(az sql server show -g "$RESOURCE_GROUP" -n "$SQL_SERVER" \
  --query fullyQualifiedDomainName -o tsv)

# ------------------------------------------------------------------- entra admin
ADMIN_UPN=$(az ad signed-in-user show --query userPrincipalName -o tsv)
ADMIN_OID=$(az ad signed-in-user show --query id -o tsv)
if [[ -z $(az sql server ad-admin list -g "$RESOURCE_GROUP" -s "$SQL_SERVER" --query "[].login" -o tsv) ]]; then
  log "Setting $ADMIN_UPN as the Entra administrator"
  az sql server ad-admin create -g "$RESOURCE_GROUP" -s "$SQL_SERVER" \
    --display-name "$ADMIN_UPN" --object-id "$ADMIN_OID" --output none
else
  log "Entra administrator already configured."
fi

# --------------------------------------------------------------------- databases
create_database() {
  local name=$1 sku=$2
  if az sql db show -g "$RESOURCE_GROUP" -s "$SQL_SERVER" -n "$name" >/dev/null 2>&1; then
    log "Database $name already exists."
  else
    log "Creating database $name ($sku)"
    az sql db create -g "$RESOURCE_GROUP" -s "$SQL_SERVER" -n "$name" \
      --service-objective "$sku" --output none
  fi
}
create_database "$DB_FULL" "$DB_FULL_SKU"
create_database "$DB_BACKUPS" "$DB_BACKUPS_SKU"

# --------------------------------------------------------------------------- vm
if az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" >/dev/null 2>&1; then
  log "VM $VM_NAME already exists."
else
  if [[ -n $VM_SIZE ]]; then
    ATTEMPT_SIZES=("$VM_SIZE")
  else
    ATTEMPT_SIZES=("${CANDIDATE_SIZES[@]}")
  fi
  CREATED=0
  for size in "${ATTEMPT_SIZES[@]}"; do
    ((CREATED == 0)) || break
    log "Attempting VM $VM_NAME with size $size"
    if az vm create \
      -g "$RESOURCE_GROUP" -n "$VM_NAME" -l "$LOCATION" \
      --image Ubuntu2404 --size "$size" \
      --admin-username "$ADMIN_USER" --generate-ssh-keys \
      --assign-identity --public-ip-sku Standard --nsg-rule SSH \
      --output none 2>/tmp/provision-vm-error.$$; then
      VM_SIZE=$size
      CREATED=1
      log "Created VM $VM_NAME ($size)"
    else
      warn "$size unavailable: $(grep -oE '"message": "[^"]{0,160}' /tmp/provision-vm-error.$$ | head -1)"
    fi
    rm -f /tmp/provision-vm-error.$$
  done
  ((CREATED == 1)) ||
    die "No candidate VM size was available in $LOCATION. Check quota with: az vm list-usage -l $LOCATION"
fi

VM_IP=$(az vm show -d -g "$RESOURCE_GROUP" -n "$VM_NAME" --query publicIps -o tsv)
SAMI_OID=$(az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" --query identity.principalId -o tsv)
[[ -n $SAMI_OID ]] ||
  die "VM $VM_NAME has no system-assigned identity. Run: az vm identity assign -g $RESOURCE_GROUP -n $VM_NAME"
# The SAMI's Entra display name equals the VM resource name, and that display
# name is the principal_name expected by the sql/ templates.
PRINCIPAL_NAME=$VM_NAME

# ---------------------------------------------------------------- firewall rules
add_firewall_rule() {
  local name=$1 ip=$2
  if [[ -z $ip ]]; then
    warn "Skipping firewall rule $name: no IP resolved."
    return 0
  fi
  log "Firewall rule $name -> $ip"
  az sql server firewall-rule create -g "$RESOURCE_GROUP" -s "$SQL_SERVER" \
    -n "$name" --start-ip-address "$ip" --end-ip-address "$ip" --output none
}
# The VM needs a rule for its outbound public IP; the operator host needs its own
# so that step 3 of the README can create SQL principals.
add_firewall_rule vm-outbound "$VM_IP"
WORKSTATION_IP=$(curl --fail --silent --show-error --max-time 10 https://api.ipify.org || true)
add_firewall_rule workstation "$WORKSTATION_IP"

# ------------------------------------------------- optional SQL principal setup
if ((SEED_FIXTURE == 1)); then
  # Order matters, and mirrors README step 3:
  #   1. Seed the application schema, because create-managed-identity-user.sql
  #      grants SELECT on schema::customer only when that schema already exists.
  #   2. Grant the master server role, because a database user created first is
  #      not remapped to a login added later.
  #   3. Create the per-database users.
  log "Seeding the customer schema into $DB_FULL"
  sqlcmd -b -S "$SQL_FQDN" -d "$DB_FULL" \
    --authentication-method ActiveDirectoryDefault \
    -i "${REPO_ROOT}/sql/test-fixtures/seed-customer-schema.sql"

  log "Granting ##MS_ServerStateReader## to $PRINCIPAL_NAME in virtual master"
  # CREATE LOGIN is rate-limited; Msg 40602 is transient.
  for attempt in 1 2 3; do
    if principal_name="$PRINCIPAL_NAME" sqlcmd -b -S "$SQL_FQDN" -d master \
      --authentication-method ActiveDirectoryDefault \
      -i "${REPO_ROOT}/sql/grant-server-state-reader.sql"; then
      break
    fi
    ((attempt < 3)) || die "Could not grant the server role after 3 attempts."
    warn "Login creation was throttled; retrying in 30s (attempt $attempt of 3)."
    sleep 30
  done

  for db in "$DB_FULL" "$DB_BACKUPS"; do
    log "Creating the managed-identity user in $db"
    principal_name="$PRINCIPAL_NAME" sqlcmd -b -S "$SQL_FQDN" -d "$db" \
      --authentication-method ActiveDirectoryDefault \
      -i "${REPO_ROOT}/sql/create-managed-identity-user.sql"
  done
fi

# -------------------------------------------------------------------- summary
umask 077
cat >"$CREDENTIALS_OUT" <<EOF
# Generated by scripts/provision-azure-test-env.sh. Untracked; do not commit.
RESOURCE_GROUP=$RESOURCE_GROUP
LOCATION=$LOCATION
VM_NAME=$VM_NAME
VM_SIZE=$VM_SIZE
VM_PUBLIC_IP=$VM_IP
VM_SSH=ssh $ADMIN_USER@$VM_IP
MANAGED_IDENTITY_PRINCIPAL_NAME=$PRINCIPAL_NAME
MANAGED_IDENTITY_OBJECT_ID=$SAMI_OID
SQL_SERVER=$SQL_SERVER
SQL_SERVER_FQDN=$SQL_FQDN
SQL_DATABASE_FULL=$DB_FULL
SQL_DATABASE_BACKUPS=$DB_BACKUPS
SQL_ADMIN_USER=$SQL_ADMIN_USER
SQL_ADMIN_PASSWORD=$SQL_ADMIN_PASSWORD
EOF
chmod 600 "$CREDENTIALS_OUT"

cat <<EOF

Provisioned. Details written to $CREDENTIALS_OUT (mode 0600).

  Resource group   $RESOURCE_GROUP ($LOCATION)
  VM               $VM_NAME ($VM_SIZE) at $VM_IP
  Identity         $PRINCIPAL_NAME  <- principal_name for README step 3
  SQL server       $SQL_FQDN
  Databases        $DB_FULL ($DB_FULL_SKU), $DB_BACKUPS ($DB_BACKUPS_SKU)

Next:
  ssh $ADMIN_USER@$VM_IP
  # then follow README.md from step 3 (or step 4 if --seed-fixture was used)

Tear everything down with:
  az group delete --name $RESOURCE_GROUP --yes --no-wait
EOF
