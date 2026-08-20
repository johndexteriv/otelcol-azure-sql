# Azure managed identity

Managed identity is the recommended authentication profile for
`otelcol-azure-sql`. It avoids a SQL password on the VM, but it requires the
patched collector binary: stock `otelcol-contrib` 0.158.0 rejects
`driver: azuresql` and does not import `go-mssqldb/azuread`.

This guide applies to **Azure SQL Database only**.

## Select and assign an identity

### System-assigned managed identity (SAMI)

A SAMI belongs to one VM. Enable it on the existing VM:

```bash
az vm identity assign \
  --resource-group <vm-resource-group> \
  --name <vm-name>

az vm identity show \
  --resource-group <vm-resource-group> \
  --name <vm-name>
```

Record `principalId`. The SAMI display name normally matches the VM resource
name. Recreating the VM creates a new identity, so the SQL principal or Entra
group membership must then be updated.

### User-assigned managed identity (UAMI)

A UAMI has an independent lifecycle and can be assigned to more than one VM:

```bash
UAMI_ID=$(az identity show \
  --resource-group <identity-resource-group> \
  --name <identity-name> \
  --query id -o tsv)

az vm identity assign \
  --resource-group <vm-resource-group> \
  --name <vm-name> \
  --identities "$UAMI_ID"

az identity show \
  --resource-group <identity-resource-group> \
  --name <identity-name> \
  --query '{clientId:clientId,principalId:principalId,id:id}'
```

Record the UAMI **client ID**. The Go driver uses that client ID to select a
UAMI. Do not substitute the principal/object ID. Put the value in
`AZURE_MANAGED_IDENTITY_CLIENT_ID` in `config/env`.

Microsoft reference: [configure managed identities on Azure
resources](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/how-to-configure-managed-identities).

## Collector DSNs

The managed-identity profile uses `driver: azuresql` and a datasource string.
The scheme remains `sqlserver://`; `azuresql` is the Go database driver name.

SAMI:

```text
sqlserver://<server>.database.windows.net:1433?database=<database>&fedauth=ActiveDirectoryManagedIdentity&encrypt=true&TrustServerCertificate=false
```

UAMI:

```text
sqlserver://<server>.database.windows.net:1433?database=<database>&fedauth=ActiveDirectoryManagedIdentity&user+id=<uami-client-id>&encrypt=true&TrustServerCertificate=false
```

`user+id` is the URL-encoded `user id` parameter. Omit it for SAMI. Always keep
`encrypt=true` and `TrustServerCertificate=false`.

Microsoft driver references:

- [`go-mssqldb` Entra authentication](https://github.com/microsoft/go-mssqldb#azure-active-directory-authentication)
- [Go driver FAQ](https://learn.microsoft.com/sql/connect/golang/faq)

## Azure RBAC is not SQL permission

Azure RBAC controls management-plane actions such as creating a logical server,
changing firewall rules, or assigning the identity to the VM. It does **not**
grant permission to connect to a database or run `SELECT`.

SQL data-plane access requires all of the following:

1. Microsoft Entra authentication configured on the Azure SQL logical server.
2. A database principal for the identity in each target database.
3. SQL `GRANT`s for the exact schemas, objects, and DMVs queried.
4. Network and DNS access from the VM.

Do not assign `SQL DB Contributor` expecting it to grant database access.
Microsoft documents this separation in [Microsoft Entra authentication for Azure
SQL](https://learn.microsoft.com/azure/azure-sql/database/authentication-aad-overview).

## Create the SQL user

Connect as the logical server's Microsoft Entra administrator, or another Entra
principal with `ALTER ANY USER`, directly to each application database. Substitute
the placeholders in the least-privilege templates under `sql/`.

With the Go `sqlcmd` executable, run the packaged template from the repository
checkout like this:

```bash
principal_name=<MANAGED_IDENTITY_DISPLAY_NAME> \
sqlcmd \
  -S <SQL_SERVER_FQDN> \
  -d <SQL_DATABASE> \
  --authentication-method ActiveDirectoryDefault \
  -i sql/create-managed-identity-user.sql
```

Repeat the command for every full-query and backup-only database. For Basic,
S0, S1, or an elastic-pool database, first run the server-role template against
virtual `master`:

```bash
principal_name=<MANAGED_IDENTITY_DISPLAY_NAME> \
sqlcmd \
  -S <SQL_SERVER_FQDN> \
  -d master \
  --authentication-method ActiveDirectoryDefault \
  -i sql/grant-server-state-reader.sql
```

For SAMI, use the VM identity display name; for UAMI, use the UAMI name:

```sql
CREATE USER [<managed-identity-name>] FROM EXTERNAL PROVIDER;
GRANT VIEW DATABASE STATE TO [<managed-identity-name>];
```

`VIEW DATABASE STATE` is all the default backup query needs. Grant `SELECT` per
schema for the queries you add, for example the `customer` schema used by the
opt-in activity-batch example:

```sql
GRANT SELECT ON SCHEMA::[customer] TO [<managed-identity-name>];
```

If a query calls a stored procedure, grant only that procedure:

```sql
GRANT EXECUTE ON OBJECT::[customer].[GetActivityBatchTenantMetrics]
TO [<managed-identity-name>];
```

Avoid `db_owner`, `db_datawriter`, and broad `CONTROL` grants. `db_datareader` is
broader than a per-schema `SELECT`; use it only if the intended query set really
needs every user table and view.

Contained users are database-scoped. Repeat the user creation and grants in every
database targeted by a named receiver in `config/queries.yaml`, including
backup-only receivers.

### Create by SID when directory lookup is unavailable

`FROM EXTERNAL PROVIDER` asks Azure SQL to resolve the name in Microsoft Entra.
For automation without the necessary Microsoft Graph access, Azure SQL Database
also supports creating a service-principal user without validation:

```sql
DECLARE @client_id UNIQUEIDENTIFIER = '<managed-identity-client-id>';
DECLARE @sid VARBINARY(16) = CONVERT(VARBINARY(16), @client_id);
DECLARE @sql NVARCHAR(MAX) =
  N'CREATE USER ' + QUOTENAME('<managed-identity-name>') +
  N' WITH SID = ' + CONVERT(NVARCHAR(34), @sid, 1) + N', TYPE = E;';
EXEC sys.sp_executesql @sql;
```

For a managed identity, use the application/client ID for this service-principal
SID form, not the principal/object ID. Azure SQL does not validate this SID at
creation time; verify it before applying grants.

Authoritative syntax: [CREATE USER
(Transact-SQL)](https://learn.microsoft.com/sql/t-sql/statements/create-user-transact-sql).

## Backup DMV permission matrix

The supplied backup query reads `sys.dm_database_backups` in the connected user
database.

| Azure SQL Database service objective | Required access | Result |
|---|---|---|
| General Purpose, Business Critical, Premium, and other non-Basic/non-S0/non-S1 single databases | `VIEW DATABASE STATE` in that database, or `##MS_ServerStateReader##` | Rows when backup history exists |
| Basic, S0, S1 | Logical server admin, Entra admin, or `##MS_ServerStateReader##` | Rows when backup history exists |
| Any database in an elastic pool | Logical server admin, Entra admin, or `##MS_ServerStateReader##` | Rows when backup history exists |
| Hyperscale | No permission changes this behavior | Zero rows; Hyperscale uses snapshot-based backups |

Treat the Basic/S0/S1 row as the requirement to design for, not as a reliable
gate. End-to-end testing on an S0 database found a plain contained user holding
only `CONNECT` and `VIEW DATABASE STATE` returning backup rows, so the DMV can be
more permissive in practice than the tier documentation promises. Granting
`##MS_ServerStateReader##` is still the correct and portable choice: it works on
every tier, and a configuration that only happens to work is one Azure change
away from returning zero rows and silently reporting `999999` backup ages.

Two behaviors to expect while granting it:

- `CREATE LOGIN` in virtual `master` is rate-limited. A burst of attempts returns
  `Msg 40602 Could not create login. Please try again later.` Wait and retry.
- `SUSER_ID()` returns `NULL` in Azure SQL even for logins that exist, so do not
  use it to test whether a login is present. Query `sys.server_principals`
  instead. Always pass `sqlcmd -b`, or a failure like the throttling error above
  exits 0 and looks like a clean run.

`##MS_ServerStateReader##` is an Azure SQL logical-server role in the **virtual
`master` database**. The identity needs a login/user in virtual `master`, role
membership there, and a user in every target database. Use the provided
least-privilege server-state template only for tiers that require it:

```sql
-- Run in virtual master as an authorized administrator.
CREATE LOGIN [<managed-identity-name>] FROM EXTERNAL PROVIDER;
ALTER SERVER ROLE [##MS_ServerStateReader##]
  ADD MEMBER [<managed-identity-name>];

-- Run separately in each target database.
CREATE USER [<managed-identity-name>]
  FROM LOGIN [<managed-identity-name>];
GRANT SELECT ON SCHEMA::[customer] TO [<managed-identity-name>];
```

Do not grant this server role on tiers where database-scoped
`VIEW DATABASE STATE` is sufficient.

Microsoft reference: [`sys.dm_database_backups`](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-database-backups-azure-sql-database).

## Validate the token from the VM

Run IMDS checks **on the Azure VM**. IMDS is link-local and should bypass HTTP
proxies.

SAMI:

```bash
curl --fail --silent --show-error --noproxy '*' \
  -H 'Metadata: true' \
  'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fdatabase.windows.net%2F' \
  | jq '{token_type, expires_on, resource, access_token_present:(.access_token|length>0)}'
```

UAMI:

```bash
curl --fail --silent --show-error --noproxy '*' \
  -H 'Metadata: true' \
  'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fdatabase.windows.net%2F&client_id=<uami-client-id>' \
  | jq '{token_type, expires_on, resource, access_token_present:(.access_token|length>0)}'
```

The requested resource/audience must be `https://database.windows.net/`. Never
paste the access token into tickets, logs, or shell history.

Microsoft reference: [use a VM managed identity to acquire a
token](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/how-to-use-vm-token).

After token acquisition succeeds, use an Entra-capable SQL client from the VM to
connect to each database and verify:

```sql
SELECT
  SUSER_SNAME() AS login_name,
  USER_NAME() AS database_user,
  DB_NAME() AS database_name;
```

Then run the exact statements from `config/queries.yaml`.

## SQL-auth fallback and rotation

Use `--profile sql-auth` only when managed identity cannot yet be deployed. It is
supported by stock `otelcol-contrib` 0.158.0 with `driver: sqlserver`.

Create a contained user in each target database:

```sql
CREATE USER [<collector-user>] WITH PASSWORD = '<generated-strong-password>';
GRANT SELECT ON SCHEMA::[customer] TO [<collector-user>];
GRANT VIEW DATABASE STATE TO [<collector-user>];
```

The datasource must name the user database; a contained user cannot authenticate
to a different database first.

One complete provisioning pattern is:

```bash
export SQLCMDUSER=<SQL_SERVER_ADMIN_USER>
read -r -s -p "SQL server admin password: " SQLCMDPASSWORD
export SQLCMDPASSWORD
export reader_user=<SQL_READER_USER>
read -r -s -p "New collector password: " reader_password
# SQLCMD performs textual substitution inside a T-SQL string. Preserve the
# original for config/env and double apostrophes only in the provisioning value.
reader_password_sql=${reader_password//\'/\'\'}
export reader_password_sql

sqlcmd -S <SQL_SERVER_FQDN> -d <SQL_DATABASE> \
  -i sql/create-sql-auth-user.sql

unset SQLCMDPASSWORD reader_password reader_password_sql
```

The password values are supplied through the process environment, not command
arguments or committed files.

For Basic, S0, S1, or an elastic-pool database, a contained SQL user cannot
satisfy the backup DMV's server-role requirement. Run
`sql/grant-server-state-reader-sql-auth.sql` in virtual `master` first, then run
`sql/create-sql-auth-user.sql` in each target database. The latter maps the
database user to the least-privilege login. On other tiers, use only
`sql/create-sql-auth-user.sql` so the principal remains database-contained.

```bash
sqlcmd -S <SQL_SERVER_FQDN> -d master \
  -i sql/grant-server-state-reader-sql-auth.sql
sqlcmd -S <SQL_SERVER_FQDN> -d <SQL_DATABASE> \
  -i sql/create-sql-auth-user.sql
```

Run these commands in the same protected shell where `SQLCMDUSER`,
`SQLCMDPASSWORD`, `reader_user`, and `reader_password_sql` were exported.

Rotate without exposing either password in source control:

1. Generate a new unique password in an approved secret manager.
2. For a contained user, run this in every target database:

   ```sql
   ALTER USER [<collector-user>]
     WITH PASSWORD = '<new-generated-strong-password>';
   ```

   If the restricted-tier path created a virtual-master login, rotate it once
   in virtual `master` with `ALTER LOGIN [<collector-user>] WITH PASSWORD =
   '<new-generated-strong-password>';` instead.

3. Update `config/env` on the VM, keep it root-owned and mode `0600`.
4. Rerun
   `sudo ./install/install.sh --profile sql-auth --replace-config`.
5. Run `sudo ./install/validate.sh` and check the journal.
6. Retire the old secret from the secret manager.

For a no-interruption rotation across many independent contained users, create a
second least-privilege user, deploy it, validate it, and then drop the old user.

Microsoft reference: [ALTER USER
(Transact-SQL)](https://learn.microsoft.com/sql/t-sql/statements/alter-user-transact-sql).
