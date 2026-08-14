-- SQL-auth fallback on Basic, S0, S1, and elastic-pool databases only.
-- Connect to the logical server's VIRTUAL MASTER database as the SQL server
-- administrator. This creates a least-privilege server login that can be added
-- to ##MS_ServerStateReader## for sys.dm_database_backups.
--
-- Example:
--   sqlcmd ... -d master \
--     -v reader_user="<SQL_READER_USER>" reader_password_sql="<SQL_ESCAPED_PASSWORD>"
--
-- Then run create-sql-auth-user.sql in every monitored user database. It will
-- map the database user to this login and grant schema SELECT.
-- reader_password_sql must contain the password with each single quote doubled;
-- keep the unmodified password in config/env for the collector.

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @reader_user sysname = N'$(reader_user)';
DECLARE @reader_password nvarchar(128) = N'$(reader_password_sql)';
DECLARE @sql nvarchar(max);

IF DB_NAME() <> N'master'
    THROW 50000, 'Connect to the Azure SQL logical server virtual master database.', 1;

IF @reader_user = N'' OR @reader_user LIKE N'<%>'
    THROW 50001, 'Set reader_user to the SQL-auth fallback username.', 1;

IF @reader_password = N'' OR @reader_password LIKE N'<%>'
    THROW 50002, 'Set reader_password to a strong unique password.', 1;

IF SUSER_ID(@reader_user) IS NULL
BEGIN
    SET @sql = N'CREATE LOGIN ' + QUOTENAME(@reader_user)
             + N' WITH PASSWORD = ' + QUOTENAME(@reader_password, '''') + N';';
    EXEC sys.sp_executesql @sql;
END;

IF NOT EXISTS (
    SELECT 1
    FROM sys.server_role_members AS srm
    INNER JOIN sys.server_principals AS role_principal
        ON role_principal.principal_id = srm.role_principal_id
    INNER JOIN sys.server_principals AS member_principal
        ON member_principal.principal_id = srm.member_principal_id
    WHERE role_principal.name = N'##MS_ServerStateReader##'
      AND member_principal.name = @reader_user
)
BEGIN
    SET @sql = N'ALTER SERVER ROLE ##MS_ServerStateReader## ADD MEMBER '
             + QUOTENAME(@reader_user) + N';';
    EXEC sys.sp_executesql @sql;
END;

SELECT
    member_principal.name AS server_principal,
    role_principal.name AS server_role
FROM sys.server_role_members AS srm
INNER JOIN sys.server_principals AS role_principal
    ON role_principal.principal_id = srm.role_principal_id
INNER JOIN sys.server_principals AS member_principal
    ON member_principal.principal_id = srm.member_principal_id
WHERE member_principal.name = @reader_user;
