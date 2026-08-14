# Custom Collector builder

Maintainer tooling for the minimal `otelcol-azure-sql` distribution. The build
uses the pinned contrib tag in `versions.env`, applies the patches in `patches/`,
and writes all clones, downloaded tools, generated module paths, and build source
under ignored `.build/`. The final binary is `dist/otelcol-azure-sql`.

```bash
./collector-builder/build.sh
TARGET_ARCH=arm64 ./collector-builder/build.sh
```

`build.sh` downloads the matching official OCB release over HTTPS to a temporary
file, verifies its SHA-256 against the reviewed value in `versions.env`, checks
the executable reports the pinned version, and then moves it into the local
cache. The contrib tag must resolve to the pinned commit before patches apply.

## Upgrade procedure

1. Update `OTEL_VERSION`, `GO_VERSION`, `CONTRIB_COMMIT`, and every supported
   host OCB SHA-256 in `versions.env` from the authoritative release.
2. Build with no overrides. Patch application is intentionally strict; inspect
   upstream changes instead of relaxing a failed patch.
3. Check whether upstream now accepts `azuresql` and blank-imports
   `github.com/microsoft/go-mssqldb/azuread`. If both are present, remove the
   obsolete patch. If only one is present, reduce the patch to the remaining
   change.
4. Review the generated `.build/builder-config.yaml` component versions and
   local replacement closure.
5. Run CI for amd64, then test the release workflow from a tag matching
   `v<OTEL_VERSION>-groundcover.<N>`.

The checked-in `builder-config.yaml` is a readable template. Never copy generated
absolute paths from `.build/builder-config.yaml` back into it.
