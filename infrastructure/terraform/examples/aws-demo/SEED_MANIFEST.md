# demo.honua.io — Maui Nui seed-data manifest

Seeded 2026-06-12 against the live demo stack (Lambda `honua-demo-demo-honua`,
RDS db.t4g.micro PostGIS 3.4.3, S3 `honua-demo-data-585192672263`). The demo
page contract is `assets/demo/layers.json` in honua-site (updated in the same
change set, branch `demo/seed-contract-sync`).

Coverage is **Maui Nui open data** — all of Maui County: Maui, Molokaʻi,
Lānaʻi, Kahoʻolawe. All datasets are public-domain / open government data,
extracted with the Maui Nui county bbox `-157.40, 20.45, -155.95, 21.25`
(EPSG:4326; the county vector datasets natively cover all four islands) and
reprojected to EPSG:4326 (vectors) / EPSG:3857 (rasters) with GDAL
(ghcr.io/osgeo/gdal:alpine-normal-latest).

## Vector layers (PostGIS tables, FeatureServer + OGC API Tiles MVT)

Pipeline per layer: ArcGIS REST → ogr2ogr (Maui Nui bbox `-spat`, reproject,
`-makevalid`, FlatGeobuf) → S3 staging (`staging-nui/`, ContentType
`application/flatgeobuf` — the import MIME allowlist rejects S3's default
`binary/octet-stream`) → `POST /api/v1/admin/import/upload-url`
(`overwriteExisting: true`) → SQL flatten of the import's JSONB `properties`
into the typed `maui_*` tables (TRUNCATE + INSERT via the postgis-bootstrap
Lambda, preserving the published tables) → re-sync of `public.features` →
extents refresh. Publications (service name == layer name == demo service id)
carry over from the original seed; layer ids are unchanged.

**`public.features` re-sync (important):** Honua serves FeatureServer queries
from the live published tables (`maui_*`) but OGC API Tiles MVT from the
canonical `public.features` table (objectid globally unique, layer_id,
geometry, attributes JSONB mirroring the flattened columns), which is
materialized at publish time and NOT updated by re-imports. After any
re-import + flatten, `public.features` must be re-synced per layer
(DELETE + INSERT with fresh global objectids) or MVT tiles keep serving the
old extent. The raster availability stubs (`maui_*_meta` + their features
rows, layers 7–9) carry the coverage bbox and were updated to the Maui Nui
envelope.

| Service (and OGC collection) | FeatureServer layer | Features (Maui Nui) | Source (geodata.hawaii.gov ArcGIS REST) | Vintage | License |
|---|---|---|---|---|---|
| maui-parcels | /rest/services/maui-parcels/FeatureServer/1 | 51,245 | ParcelsZoning/MapServer/30 "Maui County Parcels" | county data May 2025 | Public domain (Hawaii Statewide GIS / County of Maui) |
| maui-zoning | /rest/services/maui-zoning/FeatureServer/2 | 3,274 | ParcelsZoning/MapServer/33 "County Zoning - County of Maui" | July 2025 | Public domain (County of Maui) |
| maui-roads | /rest/services/maui-roads/FeatureServer/3 | 7,071 | Transportation/MapServer/5 "Maui Roads" | statewide GIS current | Public domain |
| maui-flood-hazard | /rest/services/maui-flood-hazard/FeatureServer/4 | 2,014 | Hazards/MapServer/4 "Maui County DFIRM" (FEMA) | FEMA DFIRM | Public domain (FEMA) |
| maui-sea-level-rise | /rest/services/maui-sea-level-rise/FeatureServer/5 | 3 (island multipolygons: Maui, Molokaʻi, Lānaʻi; Kahoʻolawe not modeled by UH CGG) | Climate/MapServer/45 "SLR Exposure Area - 3.2 Ft. Scenario" (UH/NOAA) | PacIOOS/UH-SOEST SLR viewer | Public domain |
| maui-place-names | /rest/services/maui-place-names/FeatureServer/6 | 2,328 | HistoricCultural/MapServer/2 "Place Names" (USGS GNIS) | GNIS | Public domain; Hawaiian diacriticals preserved (UTF-8 end to end) |

Processing notes:
- Flood simplified `-simplify 0.000005`; SLR fetched with server-side
  `maxAllowableOffset=0.00002` + `geometryPrecision=6` and 1-feature pages
  (the full statewide multipolygons overflow the ArcGIS JSON writer), then
  `-simplify 0.00002` (~2 m).
- The Honua file-import writes `imported_<table>` (id, properties JSONB,
  geometry); flattened tables (`maui_parcels` etc.) expose label/popup fields
  (tmk_txt, zone_code/zone_dist, fullname/streetname, fld_zone,
  feature_name→name/feature_class; SLR carries constant scenario_ft_32=32).
- MVT source-layer inside tiles is the constant `layer` (PostGIS ST_AsMVT).

## Raster layers (PostGIS raster, honua.raster_data)

| Service | Route | Source | Processing | License |
|---|---|---|---|---|
| maui-hillshade | /rest/services/maui-hillshade/ImageServer/tile/{z}/{y}/{x} | USGS 3DEP 1/3 arc-second, 5 tiles covering Maui Nui (s3://prd-tnm/.../n21w156, n21w157, n21w158, n22w157, n22w158) | gdalwarp → 20 m EPSG:3857 → gdaldem hillshade -z 1.3 → 6 chunks ≤8 MB → POST /api/v1/admin/import/raster → ST_Tile(256) | Public domain (USGS) |
| maui-terrain | /terrain/maui-terrain/{z}/{x}/{y}.png (Mapbox Terrain-RGB) | same 3DEP DEM | 20 m DEM resampled to 80 m (terrain endpoint samples per-pixel; 80 m + 256-px DB tiles + EXTERNAL TOAST storage keeps db.t4g.micro latency tolerable) → 2 chunks → raster import → ST_Tile(256) | Public domain (USGS) |
| maui-imagery | /rest/services/maui-imagery/ImageServer/tile/{z}/{y}/{x} | NAIP 2021 Hawaii 60 cm via NOAA Digital Coast (coastalimagery.blob.core.windows.net/digitalcoast/HI_NAIP_2021_9668, provider VRTs, EPSG:26904+26905) | gdalwarp overview reads → 20 m RGB EPSG:3857 → 16 chunks ≤8 MB → raster import → ST_Tile(256) | Public domain (USDA NAIP) |

DB-side raster post-processing (postgis-bootstrap Lambda maintenance mode):
- `honua.raster_data` migrations 001/002 applied during the original seed (the
  deployed image had not created the raster tables).
- ALL raster rows retiled with `ST_Tile(raster, 256, 256)` and the raster
  column kept on `EXTERNAL` TOAST storage. Rationale: the ImageServer/terrain
  SQL paths ST_Clip/ST_Value against whole rows, so monolithic chunk rows
  detoast 25–115 MB per tile request (the 7–16 s tiles and the bursty 500s);
  256-px rows + the ST_ConvexHull GiST index mean a tile request touches only
  the few DB tiles it intersects.

## Basemap + glyphs (S3 `honua-demo-data-585192672263`)

| Artifact | Key | Source | Serving |
|---|---|---|---|
| Protomaps basemap | `maui-basemap` (7.1 MB) | `pmtiles extract https://build.protomaps.com/20260610.pmtiles --bbox=-157.40,20.45,-155.95,21.25` (go-pmtiles docker; Maui Nui extract replaces the 5.2 MB Maui-only one) | /api/v1/tiles/pmtiles/maui-basemap (range proxy; ContentType `application/vnd.pmtiles`, S3 metadata `operation=publish`, `FileStorage__PMTilesPublish__KeyPrefix=/`) — ODbL © OpenStreetMap contributors, Protomaps |
| Noto Sans Regular SDF glyphs | `fonts/NotoSansRegular/{range}.pbf` (256 files) | github.com/openmaptiles/fonts v2.0 (OFL 1.1) | API Gateway route `GET /fonts/{proxy+}` → S3 public `fonts/` prefix (space-free stack name; APIGW HTTP proxy rejects %20 segments) |
| Staging | `staging-nui/*.fgb` (and legacy `staging/*.fgb`) | intermediate import sources | can be deleted after seeding |

## Infra changes in this branch

- `seed-data.tf`: data bucket + public `fonts/` prefix + bucket CORS, Lambda
  role S3 policy, API Gateway /fonts proxy route.
- `main.tf`: FileStorage S3 env, app CORS allowlist (https://honua.io,
  https://www.honua.io, http://localhost:8123 for site verification),
  `Limits__Connections__RequestTimeout=00:10:00` and
  `lambda_timeout_seconds=600` for bulk synchronous imports.
- `postgis-bootstrap/handler.py`: optional `{"statements":[...], "query":...}`
  maintenance mode (IAM-gated; reserved concurrency 1 on this helper only —
  the serving Lambda stays unreserved) used for schema flattening, raster
  migrations, and raster retiling — the RDS instance is only reachable in-VPC.

## Server-side objects created via admin API

- Secure connection `demo-rds` (SecretReference to the stack's
  connection-string secret) — id 4f468b76-9937-4835-9e64-ddc8012b30c1.
- 9 services (maui-parcels, maui-zoning, maui-roads, maui-flood-hazard,
  maui-sea-level-rise, maui-place-names, maui-hillshade, maui-terrain,
  maui-imagery), all with `allowAnonymous: true` read access policies.

## License posture

Server runs **Community** (no license configured). Everything the demo uses —
FeatureServer, OGC API Tiles/MVT, PostGIS-raster ImageServer tiles, the
/terrain route, the PMTiles proxy — is ungated in Community. There is no
license mint tooling in honua-server and the Ed25519 private signing key is
not in the repo (per ADR-0024/ADR-0033), so an Enterprise demo license must be
minted and supplied by the founder (`Licensing__LicensePath` +
`Licensing__TrustedKeys__<keyId>`).
