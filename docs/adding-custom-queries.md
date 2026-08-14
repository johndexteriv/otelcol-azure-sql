# Adding and changing custom queries

All customer SQL must remain visible in **`config/queries.yaml` and nowhere
else**. Do not hide SQL in the installer, service unit, generated shell, or
collector binary. `config/collector.yaml` owns connections and pipelines;
`config/queries.yaml` owns SQL and SQL-to-metric mappings.

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
          FROM customer.queue
          WHERE completed_at IS NULL
          GROUP BY queue_name;
        ignore_null_values: true
        metrics:
          - metric_name: customer.queue.pending
            value_column: pending
            data_type: gauge
            value_type: int
            description: Pending queue entries.
            unit: "{item}"
            attribute_columns: [queue_name]
            static_attributes:
              metric: queue_health
          - metric_name: customer.queue.oldest
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

- `sql` is a SQL statement or batch that returns the metric rows.
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
FROM customer.queue
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

## Supplied query intent and metrics

Keep these semantics when refactoring the SQL.

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

The existing parent roll-up
`ISNULL(parent.Reference, tenant.Reference)` must remain unless the business
meaning is intentionally changed. `sp_set_session_context` also remains if the
customer schema's row-level security depends on it.

Backup health reads `sys.dm_database_backups`, returns one row for the connected
database, and maps
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

The backup DMV is Azure SQL Database-only. The supplied query seeds one result
row from `DB_NAME()`, so an empty DMV produces `999999` age sentinels and zero
counts instead of silently dropping the metrics. On Hyperscale those sentinels
reflect the DMV's unsupported snapshot-backup model, not failed Azure backups.
See [Azure managed identity](azure-managed-identity.md#backup-dmv-permission-matrix)
for the permission matrix.

## Collection interval scope

`collection_interval`, `initial_delay`, `timeout`, and `max_open_conn` are
**receiver settings**, not query settings:

```yaml
receivers:
  sqlquery/secondary-full:
    driver: azuresql
    datasource: "sqlserver://<SQL_SERVER_FQDN>:1433?database=<SQL_DATABASE>&fedauth=ActiveDirectoryManagedIdentity&encrypt=true&TrustServerCertificate=false"
    collection_interval: ${env:SQL_COLLECTION_INTERVAL}
    initial_delay: 5s
    timeout: 30s
    max_open_conn: 2
    queries:
      - sql: |
          SELECT COUNT_BIG(*) AS pending
          FROM customer.queue
          WHERE completed_at IS NULL;
        metrics:
          - metric_name: customer.queue.pending
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

The supplied query objects have YAML anchors. After those anchor definitions in
the same `config/queries.yaml`, add one receiver instance per database and route
all instances into the same metrics pipeline:

```yaml
receivers:
  sqlquery/secondary-full:
    driver: azuresql
    datasource: "sqlserver://<SECOND_SQL_SERVER_FQDN>:1433?database=<SECOND_SQL_DATABASE>&fedauth=ActiveDirectoryManagedIdentity&user+id=${env:AZURE_MANAGED_IDENTITY_CLIENT_ID:-}&encrypt=true&TrustServerCertificate=false"
    collection_interval: ${env:SQL_COLLECTION_INTERVAL:-60s}
    initial_delay: 5s
    timeout: 30s
    max_open_conn: 2
    queries:
      - *query_activity_batch_summary
      - *query_tenant_pending
      - *query_azure_sql_backups

service:
  pipelines:
    metrics:
      receivers:
        - sqlquery/primary
        - sqlquery/secondary-full
```

The supplied SQL returns `DB_NAME() AS db_name` and includes it in every metric's
`attribute_columns`. Without it, same-named metrics from two databases can
collapse into one series. Total possible connections are
`max_open_conn × receiver count`.

Use the commented secondary receiver examples in `config/queries.yaml`; do not
copy SQL into per-database files.

## Backup-only receiver pattern

Some databases do not contain the `customer` schema but still need backup
metrics. A backup-only receiver must use the same native receiver type and a
query list containing only the backup query:

```yaml
receivers:
  sqlquery/archive-backups:
    driver: azuresql
    datasource: "sqlserver://<SQL_SERVER_FQDN>:1433?database=archive&fedauth=ActiveDirectoryManagedIdentity&user+id=${env:AZURE_MANAGED_IDENTITY_CLIENT_ID:-}&encrypt=true&TrustServerCertificate=false"
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
        - sqlquery/archive-backups
```

This is native receiver configuration. The YAML alias references the one backup
query anchored earlier in `config/queries.yaml`; SQL is not duplicated into
`collector.yaml` or another repository file.

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
