# Networking

`otelcol-azure-sql` needs two outbound paths from the existing VM:

1. Azure SQL Database over TLS/TDS.
2. The groundcover OTLP/HTTP base URL over HTTPS.

Managed identity also needs the link-local Azure Instance Metadata Service (IMDS).
No inbound collector port needs to be exposed publicly.

## Always use the normal Azure SQL FQDN

Configure:

```text
<server>.database.windows.net
```

Do not connect by IP address and do not put
`<server>.privatelink.database.windows.net` in the datasource. With a private
endpoint, Azure DNS follows the CNAME into the private zone and returns the
private IP while the client continues to use the normal FQDN. This preserves TLS
hostname validation and SQL gateway routing.

The datasource keeps:

```text
encrypt=true&TrustServerCertificate=false
```

Microsoft reference: [Azure SQL private
endpoints](https://learn.microsoft.com/azure/azure-sql/database/private-endpoint-overview).

## Connectivity options

### Private endpoint and private DNS — preferred

A private endpoint gives the logical server a private IP in a VNet. Link the
client VNet to the private DNS zone:

```text
privatelink.database.windows.net
```

From the collector VM, the normal FQDN should resolve through that zone to the
private endpoint address. Disable public network access on the logical server
after private connectivity is verified and after confirming no other approved
clients still require it.

Check routing and NSGs between the VM subnet and private endpoint subnet. For
Proxy connections, TCP 1433 is sufficient. If explicitly using Redirect with a
private endpoint, Microsoft documents broader port requirements (1433–65535 in
both directions between the client VNet and the VNet hosting the private
endpoint). If that range is not acceptable, use the Proxy policy.

Microsoft references:

- [Private endpoint DNS](https://learn.microsoft.com/azure/private-link/private-endpoint-dns)
- [Azure SQL private endpoint overview](https://learn.microsoft.com/azure/azure-sql/database/private-endpoint-overview)

### Virtual network service endpoint

A `Microsoft.Sql` service endpoint extends the VM subnet identity to the Azure SQL
service. Add an Azure SQL virtual-network firewall rule for that subnet.

Important properties:

- The SQL FQDN still resolves to a public address.
- The service endpoint is not a private endpoint and does not place the SQL
  server in the VNet.
- SQL public network access and the applicable VNet firewall rule must remain
  configured.
- Validate region and subscription constraints for the selected subnet and SQL
  server before relying on this design.

Microsoft reference: [Azure SQL virtual network service
endpoints](https://learn.microsoft.com/azure/azure-sql/database/vnet-service-endpoint-rule-overview).

### Public endpoint

For a public endpoint, allow the VM's effective outbound public IP in the Azure
SQL logical server firewall. Keep the rule as narrow as possible. An NSG, Azure
Firewall, network virtual appliance, or host firewall must also permit outbound
SQL traffic.

Avoid broad `0.0.0.0`-style access and the "Allow Azure services and resources"
setting unless the security boundary has explicitly approved it. Prefer private
endpoint connectivity for production.

Microsoft reference: [Azure SQL IP firewall
rules](https://learn.microsoft.com/azure/azure-sql/database/firewall-configure).

## Ports and Redirect behavior

All policies first reach an Azure SQL gateway on TCP `1433`.

- **Proxy:** the session remains through the gateway; outbound TCP 1433 is
  required.
- **Redirect:** after the gateway handshake, Azure redirects the client to the
  database node. For public/service-endpoint paths, allow outbound TCP
  `11000-11999` to the Azure SQL addresses for the server's region, in addition
  to TCP 1433.
- **Private endpoint + Redirect:** Microsoft documents TCP `1433-65535` between
  the involved VNets. Driver support also affects whether Redirect is used.

Do not assume that a successful `nc` to port 1433 proves Redirect traffic can
complete. If login starts and then times out, inspect the logical server
connection policy and outbound rules for the secondary range.

Use Azure service tags where supported rather than maintaining raw regional IP
lists. See [Azure SQL connectivity
architecture](https://learn.microsoft.com/azure/azure-sql/database/connectivity-architecture).

## Firewall, NSG, and outbound checklist

From the VM, permit:

- DNS to the configured resolver.
- TCP 1433 to Azure SQL.
- TCP 11000–11999 when using public/service-endpoint Redirect.
- The private-endpoint Redirect range when that policy is explicitly selected.
- TCP 443 to the configured groundcover endpoint.
- Link-local HTTP to `169.254.169.254` for IMDS; this traffic must not traverse a
  proxy.

Check every enforcement layer:

- Azure SQL server firewall and public-network setting.
- Azure SQL VNet rule for a service endpoint.
- Private endpoint connection approval and private DNS zone link.
- VM subnet NSG outbound rules.
- Private endpoint subnet policy and NSG design.
- Azure Firewall/NVA routes and application/network rules.
- Host firewall and corporate proxy configuration.
- groundcover endpoint allowlisting, if egress is restricted by FQDN.

## Diagnose from the VM

Set placeholders in the shell:

```bash
SQL_FQDN=<server>.database.windows.net
GC_HOST=exampleendpoint.grcv.io
```

### DNS

```bash
nslookup "$SQL_FQDN"
getent ahosts "$SQL_FQDN"
nslookup "$GC_HOST"
getent ahosts "$GC_HOST"
```

For a private endpoint, the SQL lookup should show the Private Link CNAME chain
and a private RFC1918 address reachable from the VM. If `nslookup` and `getent`
differ, the host's NSS configuration, local resolver, or split-horizon DNS path
needs investigation.

### TCP

```bash
nc -vz -w 5 "$SQL_FQDN" 1433
nc -vz -w 5 "$GC_HOST" 443
```

`nc` proves a TCP handshake only. It does not validate Azure SQL authentication,
TLS hostname verification, query permissions, the groundcover ingestion key, or
Redirect's secondary connection.

### TLS and HTTPS

```bash
curl --fail --silent --show-error --output /dev/null \
  --connect-timeout 5 \
  "https://$GC_HOST/"
```

An HTTP error can still prove DNS, TCP, and TLS worked. Use collector exporter
telemetry for the authenticated OTLP result; do not send an empty or fabricated
OTLP payload as a health check.

## IMDS

IMDS is available only from inside an Azure VM at `169.254.169.254`. It does not
require a route to the public internet, an Azure SQL firewall rule, or port 443.

```bash
curl --fail --silent --show-error --noproxy '*' \
  -H 'Metadata: true' \
  'http://169.254.169.254/metadata/instance?api-version=2021-02-01' \
  | jq '.compute | {name, resourceGroupName, subscriptionId}'
```

Then request the Azure SQL token as shown in [Azure managed
identity](azure-managed-identity.md#validate-the-token-from-the-vm).

If IMDS fails:

- confirm the command runs on the Azure VM, not a laptop or container without
  IMDS access;
- bypass `HTTP_PROXY`/`HTTPS_PROXY` with `--noproxy '*'` and configure
  `NO_PROXY=169.254.169.254`;
- require the exact `Metadata: true` header;
- confirm the intended SAMI/UAMI is assigned to the VM;
- specify `client_id=<uami-client-id>` when multiple UAMIs make selection
  ambiguous.

Microsoft reference: [Azure Instance Metadata
Service](https://learn.microsoft.com/azure/virtual-machines/instance-metadata-service).
