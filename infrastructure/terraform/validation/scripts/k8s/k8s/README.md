# Kubernetes Helper Scripts

This folder contains helper scripts for local Kubernetes ingress testing with the Honua Helm chart.
The workflow uses k3d (Traefik) and optionally deploys a PostGIS database for migrations.

## Quick start (k3d)

```bash
./k3d-up.sh
INGRESS_CLASS=traefik ./helm-install.sh
```

## PostGIS (recommended for migrations)

Honua migrations require PostGIS. The Bitnami PostgreSQL subchart does not include it.

```bash
./postgis-up.sh
POSTGRESQL_ENABLED=false \
DEFAULT_CONNECTION_STRING="Host=honua-postgis;Port=5432;Database=honua;Username=honua;Password=honua" \
INGRESS_CLASS=traefik \
./helm-install.sh
```

`postgis-up.sh` defaults `POSTGIS_IMAGE` to `imresamu/postgis:17-3.5-bookworm`, which is available for both `amd64` and `arm64`. Override it with `POSTGIS_IMAGE=<repo:tag>` if you need a different PostGIS image.

If you only need ingress testing, you can skip migrations:

```bash
HONUA_SKIP_MIGRATIONS=true INGRESS_CLASS=traefik ./helm-install.sh
```

## Script summary

- `k3d-up.sh` / `k3d-down.sh`: Create/delete a k3d cluster named `honua-k3d` with Traefik.
- `postgis-up.sh` / `postgis-down.sh`: Deploy/teardown a PostGIS instance in `honua` namespace.
- `postgis.yaml`: Manifest used by the PostGIS scripts.
- `helm-install.sh`: Installs/updates the Honua Helm chart with configurable env vars (see below).
- `helm-test.sh`: Runs Helm test hooks for the release.

## helm-install.sh environment variables

- `INGRESS_CLASS` (default: `nginx`) set `traefik` for k3d.
- `INGRESS_HOSTNAME` (default: `honua.local`)
- `INGRESS_PATH` / `INGRESS_PATH_TYPE` (defaults: `/` / `Prefix`)
- `LOCAL_HTTP_PORT` (default: `8080`) used for the curl hint
- `POSTGRESQL_ENABLED` (`true`/`false`)
- `DEFAULT_CONNECTION_STRING` (use when `POSTGRESQL_ENABLED=false`)
- `POSTGRES_IMAGE_REPOSITORY`, `POSTGRES_IMAGE_TAG`, `POSTGRES_IMAGE_DIGEST`
- `POSTGIS_ROLLOUT_TIMEOUT_SECONDS` (default: `300`)
- `POSTGIS_IMAGE` (default: `imresamu/postgis:17-3.5-bookworm`)
- `HONUA_IMAGE_REPOSITORY`, `HONUA_IMAGE_TAG`, `HONUA_IMAGE_PULL_POLICY`
- `HONUA_SKIP_MIGRATIONS` (`true`/`false`)
- `SECURITY_MASTER_KEY`
- `HONUA_ADMIN_PASSWORD`
- `CHART_PATH`, `RELEASE_NAME`, `NAMESPACE`

## Docs

- `../README.md`
