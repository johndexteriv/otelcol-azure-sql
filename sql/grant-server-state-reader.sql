-- Restricted Azure SQL Database tiers only: Basic, S0, S1, and elastic pools.
-- Connect to the logical server's VIRTUAL MASTER database as the Microsoft Entra
-- administrator. This grants the managed identity only the built-in server role
-- required to read sys.dm_database_backups on those tiers.
--
-- Example: sqlcmd ... -d master -v principal_name="<MANAGED_IDENTITY_DISPLAY_NAME>"
--
-- Run this file first, then run create-managed-identity-user.sql in every
-- monitored user database. That script maps the database user to this login and
-- grants schema SELECT plus VIEW DATABASE STATE.

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @principal_name sysname = N'$(principal_name)';
DECLARE @sql nvarchar(max);

IF DB_NAME() <> N'master'
    THROW 50000, 'Connect to the Azure SQL logical server virtual master database.', 1;

IF @principal_name = N'' OR @principal_name LIKE N'<%>'
    THROW 50001, 'Set principal_name to the managed identity display name.', 1;

IF NOT EXISTS (
    SELECT 1
    FROM sys.server_principals
    WHERE name = @principal_name
)
BEGIN
    SET @sql = N'CREATE LOGIN ' + QUOTENAME(@principal_name)
             + N' FROM EXTERNAL PROVIDER;';
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
      AND member_principal.name = @principal_name
)
BEGIN
    SET @sql = N'ALTER SERVER ROLE ##MS_ServerStateReader## ADD MEMBER '
             + QUOTENAME(@principal_name) + N';';
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
WHERE member_principal.name = @principal_name;
