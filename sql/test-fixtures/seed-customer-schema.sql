-- Test fixture only. Creates the minimal `customer` schema that the
-- activity-batch queries in config/queries.yaml read, then seeds rows that
-- span every age bucket and retry-limit branch so no metric is trivially zero.
--
-- Production databases already own these tables. Never run this against one.
--
-- Usage (Go sqlcmd, Entra auth):
--   sqlcmd -S <server>.database.windows.net -d <database> \
--     --authentication-method ActiveDirectoryDefault \
--     -i sql/test-fixtures/seed-customer-schema.sql
--
-- Re-running the script is safe: it drops and recreates both tables.

SET NOCOUNT ON;

IF SCHEMA_ID('customer') IS NULL
  EXEC('CREATE SCHEMA customer;');
GO

DROP TABLE IF EXISTS customer.ActivityRecordBatchInformation;
DROP TABLE IF EXISTS customer.Tenancy;
GO

CREATE TABLE customer.Tenancy (
  Id              int           NOT NULL PRIMARY KEY,
  Reference       nvarchar(128) NOT NULL,
  ParentTenantId  int           NULL
);
GO

CREATE TABLE customer.ActivityRecordBatchInformation (
  Id                    int      NOT NULL IDENTITY(1, 1) PRIMARY KEY,
  TenancyId             int      NOT NULL,
  UploadDateTime        datetime NOT NULL,
  InsertDateTime        datetime NULL,
  FailedInsertAttempts  int      NOT NULL DEFAULT 0
);
GO

-- Two roots plus one child, so the ISNULL(pt.Reference, t.Reference) rollup in
-- query_tenant_pending is exercised rather than short-circuited.
INSERT INTO customer.Tenancy (Id, Reference, ParentTenantId) VALUES
  (1, N'tenant-parent-a',     NULL),
  (2, N'tenant-child-a1',     1),
  (3, N'tenant-standalone-b', NULL);
GO

-- Pending batches: InsertDateTime IS NULL and FailedInsertAttempts < 50.
-- Age buckets in query_activity_batch_summary are cumulative, so each older
-- row also counts toward every younger bucket.
INSERT INTO customer.ActivityRecordBatchInformation
  (TenancyId, UploadDateTime, InsertDateTime, FailedInsertAttempts)
VALUES
  -- Under 5 minutes: counts toward pending only.
  (1, DATEADD(minute,  -2, GETDATE()), NULL, 0),
  (3, DATEADD(minute,  -3, GETDATE()), NULL, 0),
  -- Over 5 minutes.
  (2, DATEADD(minute, -10, GETDATE()), NULL, 1),
  (3, DATEADD(minute, -12, GETDATE()), NULL, 0),
  -- Over 15 minutes.
  (1, DATEADD(minute, -30, GETDATE()), NULL, 3),
  (2, DATEADD(minute, -45, GETDATE()), NULL, 0),
  -- Over 60 minutes.
  (1, DATEADD(minute, -90, GETDATE()), NULL, 7),
  (3, DATEADD(hour,    -4, GETDATE()), NULL, 0),
  -- Over 24 hours: also drives longest_wait_minutes and, via the row below,
  -- max_failed_attempts.
  (2, DATEADD(hour,   -30, GETDATE()), NULL, 0),
  (1, DATEADD(hour,   -49, GETDATE()), NULL, 42);
GO

-- Exactly at the retry limit: counted by failed_limit_hit, and excluded from
-- every pending bucket because those require FailedInsertAttempts < 50.
INSERT INTO customer.ActivityRecordBatchInformation
  (TenancyId, UploadDateTime, InsertDateTime, FailedInsertAttempts)
VALUES (1, DATEADD(minute, -20, GETDATE()), NULL, 50);
GO

-- Above the retry limit: counted by critical_failures only.
INSERT INTO customer.ActivityRecordBatchInformation
  (TenancyId, UploadDateTime, InsertDateTime, FailedInsertAttempts)
VALUES
  (2, DATEADD(hour, -6, GETDATE()), NULL, 75),
  (3, DATEADD(hour, -8, GETDATE()), NULL, 51);
GO

-- Already-inserted batches. Present so the queries have to filter them out
-- rather than counting every row in the table.
INSERT INTO customer.ActivityRecordBatchInformation
  (TenancyId, UploadDateTime, InsertDateTime, FailedInsertAttempts)
VALUES
  (1, DATEADD(hour, -3, GETDATE()), DATEADD(hour, -2, GETDATE()), 0),
  (3, DATEADD(hour, -9, GETDATE()), DATEADD(hour, -8, GETDATE()), 2);
GO

-- Expected values for the summary query: pending 10, pending_5m 8,
-- pending_15m 6, pending_60m 4, pending_1d 2, max_failed_attempts 42,
-- failed_limit_hit 1, critical_failures 2, and longest_wait_minutes near 2940.
SELECT
  SUM(CASE WHEN InsertDateTime IS NULL AND FailedInsertAttempts <  50 THEN 1 ELSE 0 END) AS pending,
  SUM(CASE WHEN InsertDateTime IS NULL AND FailedInsertAttempts =  50 THEN 1 ELSE 0 END) AS failed_limit_hit,
  SUM(CASE WHEN InsertDateTime IS NULL AND FailedInsertAttempts >  50 THEN 1 ELSE 0 END) AS critical_failures,
  COUNT(*)                                                                              AS total_rows
FROM customer.ActivityRecordBatchInformation;
GO
