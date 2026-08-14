-- Run against EACH monitored user database as the Microsoft Entra administrator.
-- Example: sqlcmd ... -d <SQL_DATABASE> -v principal_name="<MANAGED_IDENTITY_DISPLAY_NAME>"
--
-- This grants only the permissions used by config/queries.yaml: SELECT on the
-- customer schema when that schema exists, plus VIEW DATABASE STATE. A
-- backup-only database without customer.* therefore receives no application
-- table access. If grant-server-state-reader.sql has created a virtual-master
-- login, the database user is mapped to that login; otherwise it is contained.

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @principal_name sysname = N'$(principal_name)';
DECLARE @sql nvarchar(max);

IF @principal_name = N'' OR @principal_name LIKE N'<%>'
    THROW 50000, 'Set principal_name to the managed identity display name.', 1;

IF DATABASE_PRINCIPAL_ID(@principal_name) IS NULL
BEGIN
    IF SUSER_ID(@principal_name) IS NOT NULL
        SET @sql = N'CREATE USER ' + QUOTENAME(@principal_name)
                 + N' FROM LOGIN ' + QUOTENAME(@principal_name) + N';';
    ELSE
        SET @sql = N'CREATE USER ' + QUOTENAME(@principal_name)
                 + N' FROM EXTERNAL PROVIDER;';

    EXEC sys.sp_executesql @sql;
END;

IF SCHEMA_ID(N'customer') IS NOT NULL
BEGIN
    SET @sql = N'GRANT SELECT ON SCHEMA::customer TO '
             + QUOTENAME(@principal_name) + N';';
    EXEC sys.sp_executesql @sql;
END;

SET @sql = N'GRANT VIEW DATABASE STATE TO '
         + QUOTENAME(@principal_name) + N';';
EXEC sys.sp_executesql @sql;

SELECT
    dp.name AS database_user,
    dp.type_desc,
    dp.authentication_type_desc
FROM sys.database_principals AS dp
WHERE dp.name = @principal_name;
