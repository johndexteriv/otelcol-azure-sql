# Troubleshooting

Troubleshoot from the VM outward: configuration, identity, DNS/TCP, SQL login,
query output, local collector output, then groundcover export. This avoids
changing SQL permissions to fix a network problem or changing the network to fix
an unsupported driver.

## First commands

Run the packaged validation from the repository checkout:

```bash
sudo ./install/validate.sh
```

Validate the installed collector configuration directly:

```bash
sudo bash -c '
  set -a
  . /etc/otelcol-azure-sql/env
  set +a
  exec /usr/local/bin/otelcol-azure-sql validate \
    --config=file:/etc/otelcol-azure-sql/collector.yaml \
    --config=file:/etc/otelcol-azure-sql/queries.yaml
'
```

`validate` checks parsing and component configuration. It does not prove that a
later SQL login or exporter request succeeds. There is no supported `--dry-run`
command in this package; do not add one to copied commands.

Inspect the service:

```bash
sudo systemctl status otelcol-azure-sql --no-pager
sudo journalctl -u otelcol-azure-sql -n 200 --no-pager
sudo journalctl -u otelcol-azure-sql --since '15 minutes ago' --no-pager
sudo journalctl -u otelcol-azure-sql -f
sudo systemctl show otelcol-azure-sql -p MainPID -p NRestarts -p ExecMainStatus
```

After changing configuration:

```bash
sudo ./install/validate.sh
sudo systemctl restart otelcol-azure-sql
```

The collector does not hot-reload.

## Use the debug override

`config/debug.yaml` adds local metric output for diagnosis. It can expose metric
attributes and create high log volume, so use it briefly.

Use the installed helper to run all three config layers in a hardened transient
systemd unit:

```bash
sudo systemctl stop otelcol-azure-sql
sudo /usr/local/sbin/otelcol-azure-sql-debug
```

Wait for at least two collection intervals, inspect the emitted metric names and
attributes, then press Ctrl-C and restore the service:

```bash
sudo systemctl start otelcol-azure-sql
sudo systemctl is-active otelcol-azure-sql
```

Do not run the foreground process and systemd service together; they would make
duplicate SQL connections and duplicate datapoints.

## `Login failed for user '<token-identified principal>'`

Likely cause:

- The managed identity has no contained user in the connected database.
- The wrong SAMI/UAMI was selected.
- A SID-based user was created with the wrong ID.
- The user exists in another database but not the one named in the DSN.

Verify:

```bash
# SAMI token
curl --fail --silent --show-error --noproxy '*' \
  -H 'Metadata: true' \
  'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fdatabase.windows.net%2F' \
  | jq '{resource,expires_on,access_token_present:(.access_token|length>0)}'
```

For UAMI, add `&client_id=<uami-client-id>`. As an Entra SQL administrator,
connect to the exact target database and check:

```sql
SELECT name, type_desc, authentication_type_desc
FROM sys.database_principals
WHERE name = N'<managed-identity-name>';
```

Fix:

- Create the user and grants in every target database.
- For UAMI, set `user id` to the **client ID** in the managed-identity DSN.
- For a SID-created service-principal user, recreate it with the client ID and
  `TYPE = E`.
- Restart the collector after changing identity selection.

See [Azure managed identity](azure-managed-identity.md).

## `Login failed for user ''`

Likely cause: `driver: sqlserver` was combined with
`fedauth=ActiveDirectoryManagedIdentity`. Stock 0.158.0's base SQL Server driver
does not activate the `azuread` package.

Verify:

```bash
sudo journalctl -u otelcol-azure-sql --since '15 minutes ago' --no-pager
```

Fix: use the custom binary and `driver: azuresql` for managed identity, or select
the stock `sql-auth` profile with a real SQL username/password. Do not try to pass
`fedauth` through `additional_params`.

## `unsupported driver: azuresql`

Likely cause: the managed-identity config is being validated by stock
`otelcol-contrib` 0.158.0, or the wrong binary is installed.

Verify:

```bash
/usr/local/bin/otelcol-azure-sql --version
sudo systemctl show otelcol-azure-sql -p ExecStart
```

Fix:

```bash
sudo ./install/install.sh --profile managed-identity --replace-config
sudo ./install/validate.sh
```

Confirm the configured GitHub release repository contains the tagged
`otelcol-azure-sql` artifact for the VM architecture. The packaged default is
`johndexteriv/otelcol-azure-sql`; override it only when using an approved
mirror or fork.

## `Cannot open server '<name>' requested by the login`

Likely cause:

- The server placeholder in `config/queries.yaml` is wrong or contains a database
  name.
- A contained SQL-auth user connected without the target database in the DSN.
- The logical server name belongs to another tenant/server.

Verify:

```bash
sudo grep -E '^[[:space:]]*(host|datasource):' \
  /etc/otelcol-azure-sql/queries.yaml
```

The server must be `<server>.database.windows.net`, and each datasource must set
`database=<target-database>`.

Fix: correct `config/env`, rerun the installer with the same profile, validate,
and restart. For contained SQL users, create the user in and connect directly to
each target database.

## TCP timeout or connection refused

Likely cause:

- DNS points to an unreachable address.
- Azure SQL firewall or VNet rule is missing.
- NSG, Azure Firewall/NVA, route table, host firewall, or proxy blocks traffic.
- Redirect is selected but TCP 11000–11999 is blocked.
- Private endpoint DNS or peering is incomplete.

Verify from the VM:

```bash
SQL_FQDN=<server>.database.windows.net
nslookup "$SQL_FQDN"
getent ahosts "$SQL_FQDN"
nc -vz -w 5 "$SQL_FQDN" 1433
```

Fix: follow [Networking](networking.md). For public/service-endpoint Redirect,
permit outbound 1433 and 11000–11999 to the documented Azure SQL destinations.
For private endpoint connectivity, confirm the private DNS zone link and selected
connection policy.

## Certificate or TLS hostname failure

Likely cause:

- The datasource uses an IP address or the `privatelink` hostname.
- TLS interception replaces Azure SQL's certificate.
- `TrustServerCertificate`/encryption parameters were altered.
- The VM trust store or clock is invalid.

Verify:

```bash
date -u
getent ahosts <server>.database.windows.net
```

Fix:

- Connect with `<server>.database.windows.net`.
- Keep `encrypt=true&TrustServerCertificate=false`.
- Repair the VM trust store/time synchronization.
- Bypass unsupported TLS interception for Azure SQL.

Do not set `TrustServerCertificate=true` as a permanent fix.

## IMDS request fails or selects the wrong identity

Likely cause:

- The command is not running on the Azure VM.
- The identity is not assigned to the VM.
- An HTTP proxy captures link-local traffic.
- Multiple UAMIs are assigned and no selector is provided.
- The required `Metadata: true` header is absent.

Verify:

```bash
curl --fail --silent --show-error --noproxy '*' \
  -H 'Metadata: true' \
  'http://169.254.169.254/metadata/instance?api-version=2021-02-01' \
  | jq '.compute | {name,resourceGroupName}'
```

Fix:

- Assign SAMI/UAMI to the VM.
- Set `NO_PROXY=169.254.169.254` for the service.
- For UAMI, use the UAMI client ID in the token request and collector DSN.
- Request the Azure SQL resource exactly as
  `https://database.windows.net/`.

## Service is in a restart loop

Likely cause:

- YAML/environment expansion failed.
- The selected binary does not support the selected profile.
- Both foreground debug and systemd instances are running.
- A local extension/telemetry port is already in use.
- File permissions prevent the service account from reading installed config.

Verify:

```bash
sudo systemctl status otelcol-azure-sql --no-pager
sudo journalctl -u otelcol-azure-sql -b --no-pager
sudo systemctl show otelcol-azure-sql -p NRestarts -p ExecMainStatus
sudo ss -lntp
```

Fix:

1. Stop the service.
2. End any foreground collector.
3. Run the exact direct `validate` command at the top of this guide.
4. Correct the first configuration error in the journal.
5. Rerun the installer for the intended profile.
6. Start the service and watch `NRestarts` for several intervals.

`NRestarts` is cumulative while the unit is loaded; a static nonzero value is not
itself a live crash loop.

## Service is active but no SQL metrics exist

Likely cause:

- The receiver is not listed in the metrics pipeline.
- The query returns zero rows.
- A mapped value is NULL or nonnumeric.
- The collection interval has not elapsed.
- The wrong database list/profile is installed.
- A multi-statement batch returns an earlier result set.

Verify:

```bash
sudo journalctl -u otelcol-azure-sql --since '15 minutes ago' --no-pager
```

Run the exact SQL from `config/queries.yaml` manually as the collector principal.
Then use the debug override and wait two intervals.

Fix:

- Add every named receiver to `service.pipelines.metrics.receivers`.
- Correct the query to return the expected rows and numeric columns.
- Wrap nullable mapped values with a deliberate `ISNULL`/`COALESCE`.
- Keep row-producing statements before the metric `SELECT` out of a
  multi-statement batch.
- Reinstall with `--replace-config` after adding or removing named receivers in
  `config/queries.yaml`.

## Malformed query or `Invalid object name`

Likely cause:

- T-SQL syntax or an identifier is wrong.
- The receiver connects to the wrong database.
- A receiver runs a query against a database that lacks the objects it needs.
  Enabling the commented activity-batch example on a database without the
  `customer` schema does exactly this.
- SQL was copied somewhere other than `config/queries.yaml` and drifted.

Verify:

- Execute the exact query from `config/queries.yaml` against the exact database.
- Confirm `DB_NAME()` and the required schema/objects.
- Read the SQL error in the collector journal.

Fix:

- Keep the corrected SQL and mapping only in `config/queries.yaml`.
- Give that database its own receiver with a reduced query list containing only
  the queries its schema supports. `*query_azure_sql_backups` runs anywhere.
- Validate and restart.

## Permission denied while a query runs

Likely cause:

- A query you added reads a schema the collector principal has no `SELECT` on.
  The `sql/` scripts grant only `VIEW DATABASE STATE` and, where the schema
  exists, `SELECT ON SCHEMA::customer`.
- `SELECT ON SCHEMA::customer` is missing, which affects only queries against
  that schema, including the opt-in activity-batch example. The grant is skipped
  when the schema did not exist at the time the script ran.
- A stored procedure needs a separate `EXECUTE` grant.
- Backup DMV permission differs for the database service objective.
- Grants were applied in another database.

Verify as an administrator in the target database, substituting the schema your
query reads:

```sql
SELECT
  HAS_PERMS_BY_NAME(N'customer', N'SCHEMA', N'SELECT') AS can_select_schema,
  HAS_PERMS_BY_NAME(DB_NAME(), N'DATABASE', N'VIEW DATABASE STATE')
    AS can_view_database_state;
```

Fix:

- Apply the least-privilege template in every target database, then rerun it if
  the schema was created afterwards.
- Grant `SELECT` on each additional schema your own queries read.
- Grant `EXECUTE` only on the required procedure when used.
- For Basic, S0, S1, or elastic-pool databases, use the documented
  `##MS_ServerStateReader##` virtual-master pattern.
- Do not solve read-only monitoring failures by granting `db_owner`.

## Backup metrics show `999999` ages and zero counts

Likely cause, in order:

1. A newly created database has no visible backup history yet.
2. Hyperscale uses snapshot-based backups; this DMV returns no rows by design.
3. The receiver is connected to `master` or another database.
4. The database needs the service-tier-specific permission.

Verify:

```sql
SELECT
  DB_NAME() AS database_name,
  DATABASEPROPERTYEX(DB_NAME(), 'Edition') AS edition,
  DATABASEPROPERTYEX(DB_NAME(), 'ServiceObjective') AS service_objective;

SELECT TOP (10)
  logical_database_name, backup_type, backup_finish_date
FROM sys.dm_database_backups
ORDER BY backup_finish_date DESC;
```

Fix:

- For Hyperscale, source backup health from Azure Monitor; no SQL grant changes
  the DMV behavior. The supplied SQL emits sentinels so the series remains
  observable, but those values do not describe Hyperscale snapshot health.
- For a new database, wait for backup history rather than fabricating production
  data.
- Connect one receiver directly to each user database.
- Apply the tier-appropriate grants in [Azure managed
  identity](azure-managed-identity.md#backup-dmv-permission-matrix).

## Metrics appear locally but not in groundcover

Likely cause:

- The endpoint is not the full `https://` base URL.
- `/v1/metrics` was added manually and is now doubled.
- TCP 443, DNS, proxy, or TLS blocks egress.
- The key is not an active **Third Party** ingestion key.
- The `apikey` header is absent.
- The exporter is not in the metrics pipeline.

Verify:

```bash
GC_URL=$(sudo awk -F= '$1=="GROUNDCOVER_OTLP_ENDPOINT"{print substr($0,index($0,"=")+1)}' \
  /etc/otelcol-azure-sql/env)
GC_HOST=${GC_URL#https://}
GC_HOST=${GC_HOST%%/*}
getent ahosts "$GC_HOST"
nc -vz -w 5 "$GC_HOST" 443
sudo journalctl -u otelcol-azure-sql --since '15 minutes ago' --no-pager
```

Fix:

- Set `GROUNDCOVER_OTLP_ENDPOINT=https://exampleendpoint.grcv.io` with no
  `/v1/metrics`.
- Use port 443.
- Put the Third Party key in `apikey`.
- Ensure `otlp_http/groundcover` is in the metrics pipeline.
- Correct outbound HTTPS and proxy trust.

Never print the ingestion key while debugging.

## groundcover accepted data but metrics are not found

Likely cause:

- The searched name uses dots instead of underscores.
- A dimensionless unit added `_ratio`.
- Persistent UI environment/workload filters exclude the series.
- Attribution fields are missing or inconsistent.
- Fewer than two collection intervals have elapsed.

Verify by searching broad metric prefixes:

```text
azure_sql_backups_
```

Add the prefix of each query you added to `config/queries.yaml`. With the
commented activity-batch example enabled, that is `activity_batch_` and
`activity_batch_tenants_`.

Fix:

- Search `azure_sql_backups_last_full_age_hours`, not
  `azure_sql_backups.last_full_age_hours`. Dots become underscores.
- Search `azure_sql_backups_has_full_backup_last_7d_ratio` for the unit-`1`
  boolean.
- Clear UI filters, then filter with `env`, `service_name`, `gc_env_type`,
  `source`, and `db_name`. The label arrives as `gc_env_type`, not `env_type`.
- Confirm the exporter/resource configuration supplies `env_name`,
  `service.name`, `gc_env_type`, and `source`.

groundcover references:

- [Send from an OpenTelemetry Collector](https://docs.groundcover.com/integrations/data-sources/opentelemetry/sending-from-an-opentelemetry-collector)
- [Enrich third-party data](https://docs.groundcover.com/integrations/data-sources/enriching-3rd-party-data)
