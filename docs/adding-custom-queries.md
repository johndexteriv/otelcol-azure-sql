# Adding and changing custom queries

**Any T-SQL that returns numeric columns can become a metric.** A plain `SELECT`,
a CTE, a DMV read, a multi-statement batch, or an `EXEC` of a stored procedure
that returns a rowset all work. There is no fixed metric catalog: you pair SQL
with a mapping that says which returned columns are values and which are labels.

All customer SQL must remain visible in **`config/queries.yaml` and nowhere
else**. Do not hide SQL in the installer, service unit, generated shell, or
collector binary. `config/collector.yaml` owns connections and pipelines;
`config/queries.yaml` owns SQL and SQL-to-metric mappings.

The package ships one active query, Azure SQL backup health, which works on any
Azure SQL Database. `config/queries.yaml` also carries a commented starter
template to copy and a commented opt-in example; see
[Shipped queries](#shipped-queries).

The package uses the native OpenTelemetry contrib `sqlquery` receiver schema from
the pinned 0.158.0 base. The receiver's metrics support is alpha, so validate the
configuration before every rollout.

## Native schema

This is the supported native shape for one receiver and query inside
`config/queries.yaml`:

```yaml
receivers:
  sqlquery/example:
    driver: azuresql
    datasource: "sqlserver://<SQL_SERVER_FQDN>:1433?database=<SQL_DATABASE>&fedauth=ActiveDirectoryManagedIdentity&encrypt=true&TrustServerCertificate=false"
    collection_interval: ${env:SQL_COLLECTION_INTERVAL:-60s}
    initial_delay: 5s
    timeout: 30s
    max_open_conn: 2
    queries:
      - sql: |
          SELECT
            COUNT_BIG(*) AS pending,
            CAST(MAX(DATEDIFF(SECOND, created_at, SYSUTCDATETIME())) AS FLOAT)
              AS oldest_seconds,
            queue_name
          FROM dbo.Queue
          WHERE completed_at IS NULL
          GROUP BY queue_name;
        ignore_null_values: true
        metrics:
          - metric_name: app.queue.pending
            value_column: pending
            data_type: gauge
            value_type: int
            description: Pending queue entries.
            unit: "{item}"
            attribute_columns: [queue_name]
            static_attributes:
              metric: queue_health
          - metric_name: app.queue.oldest
            value_column: oldest_seconds
            data_type: gauge
            value_type: double
            description: Age of the oldest pending queue entry.
            unit: s
            attribute_columns: [queue_name]
            static_attributes:
              metric: queue_health

service:
  pipelines:
    metrics:
      receivers: [sqlquery/example]
```

Rules:

- `sql` is any T-SQL statement or batch that returns the metric rows, including a
  CTE, a DMV read, or `EXEC` of a procedure whose final statement is a `SELECT`.
  A batch with several statements must end with the row-returning one; use
  `SET NOCOUNT ON;` so intermediate row counts do not confuse the driver.
- `metrics` is a list. Each item emits one OpenTelemetry metric for each result
  row.
- `metric_name` and `value_column` are required.
- `value_column` must refer to a returned **numeric** column.
- `data_type` is `gauge` or `sum`; it defaults to `gauge`.
- `value_type` is `int` or `double`; it defaults to `int`.
- `monotonic` and `aggregation` apply only to sums. `aggregation` is
  `cumulative` or `delta`.
- `description` and `unit` describe the resulting metric.
- `attribute_columns` identifies returned columns copied to datapoint labels. Put
  it on each metric mapping so the label set is explicit.
- `static_attributes` adds bounded constant labels.
- `ignore_null_values` suppresses warnings for unused NULL columns. It does not
  make a NULL `value_column` numeric.

Reference: [SQL Query receiver
0.158.0](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/v0.158.0/receiver/sqlqueryreceiver).

## Return numeric value columns

The receiver converts values according to `value_type`. Make conversion explicit
in T-SQL:

```sql
SELECT
  COUNT_BIG(*) AS item_count,                         -- value_type: int
  CAST(AVG(CAST(duration_ms AS FLOAT)) AS FLOAT)
    AS average_duration_ms,                           -- value_type: double
  queue_name                                          -- attribute column
FROM dbo.Queue
GROUP BY queue_name;
```

Use `ISNULL`/`COALESCE` for every mapped value that can be NULL. A NULL in a
`value_column` can fail that datapoint even when `ignore_null_values: true`.
Choose a sentinel with deliberate alert semantics. The supplied backup age
metrics use `999999`: a backup that never happened should look very stale, not
healthy.

Return stable, bounded text columns for labels. Avoid request IDs, timestamps,
free-form errors, and unbounded tenant identifiers unless their series cost is
understood.

## Metric mapping fields

Use these mappings consistently:

- **Gauge + int:** current counts, retry counts, and point-in-time booleans.
- **Gauge + double:** ages, durations, and ratios that can have fractional
  values.
- **Sum:** only when the SQL value has true additive temporality. Set
  `aggregation` and `monotonic` intentionally.
- **Result labels:** `attribute_columns`, such as `databaseid` or `dbname`.
- **Constant labels:** `static_attributes`, such as `metric` and the receiver's
  `db_name`.

Do not put connection-wide attribution into every query mapping.
`env_name`, `service.name`, `gc_env_type`, and `source` belong in the resource or
groundcover exporter configuration. `db_name` is the exception because it varies
per database receiver.

## Shipped queries

### Default: Azure SQL backup health

This is the only active query. It works on any Azure SQL Database, needs no
application schema, and needs only the `VIEW DATABASE STATE` grant that the
`sql/` user scripts apply. It reads `sys.dm_database_backups`, returns one row for
the connected database, and maps
`attribute_columns: [dbname, db_name, sql_server_name]` with static attributes
`env=${env:GROUNDCOVER_ENV_NAME}` and `metric=azure_sql_backups`:

- `lastfullagehours` → `azure_sql_backups.last_full_age_hours`, double, `h`
- `lastdiffagehours` → `azure_sql_backups.last_diff_age_hours`, double, `h`
- `lastlogagehours` → `azure_sql_backups.last_log_age_hours`, double, `h`
- `hasfullbackuplast7days` →
  `azure_sql_backups.has_full_backup_last_7d`, double, `1`
- `hasdiffbackuplast2days` →
  `azure_sql_backups.has_diff_backup_last_2d`, double, `1`
- `haslogbackuplast60min` →
  `azure_sql_backups.has_log_backup_last_60m`, double, `1`
- `fullbackups7dcount` → `azure_sql_backups.full_backups_7d_count`, double,
  `{backup}`
- `diffbackups2dcount` → `azure_sql_backups.diff_backups_2d_count`, double,
  `{backup}`
- `logbackups24hcount` → `azure_sql_backups.log_backups_24h_count`, double,
  `{backup}`

The backup DMV is Azure SQL Database-only. The query seeds one result row from
`DB_NAME()`, so an empty DMV produces `999999` age sentinels and zero counts
instead of silently dropping the metrics. On Hyperscale those sentinels reflect
the DMV's unsupported snapshot-backup model, not failed Azure backups.
See [Azure managed identity](azure-managed-identity.md#backup-dmv-permission-matrix)
for the permission matrix.

### Opt-in example: activity-batch backlog

These two queries ship **commented out** in `config/queries.yaml`. They are one
application's monitoring, kept as a worked example of a multi-table,
multi-metric query pair, not a package feature. Treat them as a pattern to adapt
rather than something to enable verbatim.

Schema contract. Enabling them without this schema produces
`Invalid object name` every collection interval:

- `customer.ActivityRecordBatchInformation` with `Id`, `TenancyId`,
  `UploadDateTime`, `InsertDateTime`, `FailedInsertAttempts`.
- `customer.Tenancy` with `Id`, `Reference`, `ParentTenantId`.

Behavioral assumptions baked into the SQL:

- The failed-insert retry limit is the literal `50`. A batch at exactly 50 is
  `failed_limit_hit`; above 50 it is a `critical_failure`.
- A pending batch is one where `InsertDateTime IS NULL`.
- The tenant query runs
  `EXEC sp_set_session_context @key=N'IsLogin', @value=1` because that schema's
  row-level security depends on it, and it reads with `WITH(NOLOCK)`.
- The collector principal needs `SELECT ON SCHEMA::customer`. The `sql/` user
  scripts grant it only when the schema already exists, so rerun the relevant
  script after creating the schema.

To enable, strip the `# ` prefix from every line of the two query blocks. That
also restores the `query_activity_batch_summary` and `query_tenant_pending`
anchors for reuse by other receivers. To exercise them on a scratch database,
seed it with `sql/test-fixtures/seed-customer-schema.sql`.

Keep these semantics if you adapt the SQL.

Activity-batch summary returns one row and nine integer gauges. Every mapping has
`attribute_columns: [db_name, sql_server_name]` and static attributes
`env=${env:GROUNDCOVER_ENV_NAME}` and `metric=pending_batch_uploads`:

- `pending` → `activity_batch.pending`, unit `{batch}`
- `pending5mins` → `activity_batch.pending_5m`, unit `{batch}`
- `pending15mins` → `activity_batch.pending_15m`, unit `{batch}`
- `pending60mins` → `activity_batch.pending_60m`, unit `{batch}`
- `pending1day` → `activity_batch.pending_1d`, unit `{batch}`
- `longestwaitmins` → `activity_batch.longest_wait_minutes`, unit `min`
- `maxfailedattempts` → `activity_batch.max_failed_attempts`, unit `{attempt}`
- `failedlimithit` → `activity_batch.failed_limit_hit`, unit `{batch}`
- `criticalfailures` → `activity_batch.critical_failures`, unit `{batch}`

The pending age buckets are cumulative, not mutually exclusive.

Tenant pending returns one row per top-level tenant and four integer gauges. Each
mapping carries
`attribute_columns: [databaseid, db_name, sql_server_name]` and the same
`env`/`metric=pending_batch_uploads` static attributes:

- `pending` → `activity_batch_tenants.pending`
- `pending5mins` → `activity_batch_tenants.pending_5m`
- `pending15mins` → `activity_batch_tenants.pending_15m`
- `pending60mins` → `activity_batch_tenants.pending_60m`

The parent roll-up `ISNULL(parent.Reference, tenant.Reference)` must remain
unless the business meaning is intentionally changed.

## Collection interval scope

`collection_interval`, `initial_delay`, `timeout`, and `max_open_conn` are
**receiver settings**, not query settings:

```yaml
receivers:
  sqlquery/slow-queries:
    driver: azuresql
    datasource: "sqlserver://<SQL_SERVER_FQDN>:1433?database=<SQL_DATABASE>&fedauth=ActiveDirectoryManagedIdentity&encrypt=true&TrustServerCertificate=false"
    collection_interval: ${env:SQL_COLLECTION_INTERVAL}
    initial_delay: 5s
    timeout: 30s
    max_open_conn: 2
    queries:
      - sql: |
          SELECT COUNT_BIG(*) AS pending
          FROM dbo.Queue
          WHERE completed_at IS NULL;
        metrics:
          - metric_name: app.queue.pending
            value_column: pending
            data_type: gauge
            value_type: int
```

Every query in that receiver runs on the same interval. If one query needs a
different interval, create a second receiver with only that query. Do not add
`collection_interval` under an individual query.

Evaluate query cost against the interval. A 60-second scrape that takes 50
seconds leaves little safety margin and can keep a serverless database active.

## Multi-database pattern

Active query objects have YAML anchors, and an alias can only reference an anchor
that is active. `&query_azure_sql_backups` is the only anchor defined as shipped;
your own queries should be anchored too if more than one receiver needs them.
After the anchor definitions in the same `config/queries.yaml`, add one receiver
instance per database and route all instances into the same metrics pipeline:

```yaml
receivers:
  sqlquery/secondary:
    driver: azuresql
    datasource: "sqlserver://<SECOND_SQL_SERVER_FQDN>:1433?database=<SECOND_SQL_DATABASE>&fedauth=ActiveDirectoryManagedIdentity&user+id=${env:AZURE_MANAGED_IDENTITY_CLIENT_ID:-}&encrypt=true&TrustServerCertificate=false"
    collection_interval: ${env:SQL_COLLECTION_INTERVAL:-60s}
    initial_delay: 5s
    timeout: 30s
    max_open_conn: 2
    queries:
      - *query_azure_sql_backups

service:
  pipelines:
    metrics:
      receivers:
        - sqlquery/primary
        - sqlquery/secondary
```

The supplied SQL returns `DB_NAME() AS db_name` and includes it in every metric's
`attribute_columns`. Do the same in your own queries: without it, same-named
metrics from two databases can collapse into one series. Total possible
connections are `max_open_conn × receiver count`.

Use the commented secondary receiver examples in `config/queries.yaml`; do not
copy SQL into per-database files.

## Per-database query sets

Databases rarely have identical schemas, so a receiver's query list should
contain only the queries valid for that database. Alias the shared ones and
define the database-specific ones inline:

```yaml
receivers:
  sqlquery/archive:
    driver: azuresql
    datasource: "sqlserver://<SQL_SERVER_FQDN>:1433?database=archive&fedauth=ActiveDirectoryManagedIdentity&user+id=${env:AZURE_MANAGED_IDENTITY_CLIENT_ID:-}&encrypt=true&TrustServerCertificate=false"
    collection_interval: ${env:SQL_COLLECTION_INTERVAL:-60s}
    initial_delay: 5s
    timeout: 30s
    max_open_conn: 2
    queries:
      - *query_azure_sql_backups
      - sql: |
          SELECT COUNT_BIG(*) AS archived_rows FROM dbo.ArchivedActivity;
        metrics:
          - metric_name: app.archive.rows
            value_column: archived_rows
            data_type: gauge
            value_type: int

service:
  pipelines:
    metrics:
      receivers:
        - sqlquery/primary
        - sqlquery/archive
```

This is native receiver configuration. The YAML alias references the backup query
anchored earlier in `config/queries.yaml`, and the inline query lives beside it;
SQL is not duplicated into `collector.yaml` or another repository file.

A receiver whose database lacks the objects a query needs is the common cause of
repeating `Invalid object name` errors. Give that database its own receiver with a
reduced query list rather than granting it a query it cannot run.

## Add, remove, or modify a query

1. Edit only `config/queries.yaml`.
2. Run the SQL manually against a non-production or read-only target with the
   collector principal.
3. Confirm every `value_column` exists, is numeric, and is non-NULL for expected
   edge cases.
4. Confirm labels are bounded and the query returns the intended number of rows.
5. Add or update the metric mapping beside the SQL.
6. Validate before restart:

   ```bash
   sudo ./install/validate.sh
   ```

7. Reinstall the current profile and restart:

   ```bash
   sudo ./install/install.sh --profile managed-identity --replace-config
   ```

8. Enable the debug override briefly and compare local datapoints with direct SQL
   results.
9. Verify translated names and attribution in groundcover for at least two
   intervals.

When removing a metric, remember that its historical series remains queryable
until groundcover retention expires. When changing a name or label set, treat it
as a new time series and update dashboards and alerts.

## Datadog custom-query migration

Map Datadog DBM custom query fields to native `sqlquery` fields:

- Datadog `query` → `sql`
- Datadog `metric_prefix` + gauge/count column `name` → explicit `metric_name`
- Datadog numeric column with `type: gauge`, `count`, or `rate` → a numeric
  `value_column` plus an intentional OTel `data_type`/`value_type`
- Datadog column with `type: tag` → `attribute_columns`
- Datadog static `tags` → `static_attributes` or shared resource attributes
- Datadog instance/check interval → receiver `collection_interval`
- One Datadog Azure SQL Database instance per database → one named `sqlquery`
  receiver per database

Do not translate `count` mechanically to an OTel sum. A SQL query that returns
the current number of rows is a gauge even if Datadog calls the column a count.
Use an OTel sum only for a cumulative or delta quantity with known reset and
temporality behavior.

Datadog may prefix metric names automatically; the OTel receiver does not.
Declare the complete target name explicitly and account for groundcover's
Prometheus-compatible name translation.
