-- Stock-Collector fallback only. Run against EACH monitored user database as an
-- administrator. VIEW DATABASE STATE covers the default backup query. SELECT on
-- the customer schema is granted only when that schema exists, for the opt-in
-- activity-batch example; queries you add against other schemas need their own
-- SELECT grants. Prefer create-managed-identity-user.sql for normal operation.
--
-- Example:
--   sqlcmd ... -d <SQL_DATABASE> \
--     -v reader_user="<SQL_READER_USER>" reader_password_sql="<SQL_ESCAPED_PASSWORD>"
--
-- SQLCMD performs textual substitution. If either value contains a single quote,
-- reader_password_sql MUST contain the password with each single quote doubled.
-- Keep the original password in config/env for the collector. If
-- grant-server-state-reader-sql-auth.sql created a virtual-master login first,
-- this script maps the user to that login; otherwise it creates a contained user.

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @reader_user sysname = N'$(reader_user)';
DECLARE @reader_password nvarchar(128) = N'$(reader_password_sql)';
DECLARE @sql nvarchar(max);

IF @reader_user = N'' OR @reader_user LIKE N'<%>'
    THROW 50000, 'Set reader_user to the contained database username.', 1;

IF @reader_password = N'' OR @reader_password LIKE N'<%>'
    THROW 50001, 'Set reader_password to a strong unique password.', 1;

IF DATABASE_PRINCIPAL_ID(@reader_user) IS NULL
BEGIN
    IF SUSER_ID(@reader_user) IS NOT NULL
        SET @sql = N'CREATE USER ' + QUOTENAME(@reader_user)
                 + N' FROM LOGIN ' + QUOTENAME(@reader_user) + N';';
    ELSE
        SET @sql = N'CREATE USER ' + QUOTENAME(@reader_user)
                 + N' WITH PASSWORD = ' + QUOTENAME(@reader_password, '''') + N';';

    EXEC sys.sp_executesql @sql;
END;

IF SCHEMA_ID(N'customer') IS NOT NULL
BEGIN
    SET @sql = N'GRANT SELECT ON SCHEMA::customer TO '
             + QUOTENAME(@reader_user) + N';';
    EXEC sys.sp_executesql @sql;
END;

SET @sql = N'GRANT VIEW DATABASE STATE TO '
         + QUOTENAME(@reader_user) + N';';
EXEC sys.sp_executesql @sql;

SELECT
    dp.name AS database_user,
    dp.type_desc,
    dp.authentication_type_desc
FROM sys.database_principals AS dp
WHERE dp.name = @reader_user;
