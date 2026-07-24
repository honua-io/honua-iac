###############################################################################
# Amazon Location Service geocoding provider (honua-server#2948).
#
# Context: the demo's original Nominatim (OpenStreetMap) geocoding provider is
# unreachable from a no-NAT/no-IGW VPC — every forward/reverse geocode call
# fails after a consistent ~15.8s outbound-connect timeout, not a cold-start
# issue. Amazon Location Service is reachable over AWS's private network via a
# VPC interface endpoint (com.amazonaws.<region>.geo — provisioned by the
# calling example root, not here, since VPC endpoints are VPC-specific), so it
# needs no NAT gateway and no general internet egress.
#
# The server already ships an amazon-location geocoding provider
# (Honua.Geocoding.Features.Geocoding.Providers.AmazonLocationGeocodeProvider)
# that calls the classic Amazon Location Places v1 API
# (SearchPlaceIndexForText / SearchPlaceIndexForPosition /
# SearchPlaceIndexForSuggestions) against a named place index, authenticating
# via the AWS credential chain (the Lambda execution role) when
# Geocoding:Providers:AmazonLocation:UseIamRole is true (the default) — no
# access keys needed.
#
# Data-source note: results come from Esri (or HERE) via Amazon Location, NOT
# OpenStreetMap/Nominatim. Coverage, address formatting, and attribution
# requirements differ (Esri/HERE terms of use apply); this is a full provider
# swap, not a drop-in replacement with identical results.
#
# Toggled off by default so existing deploys are unchanged unless an operator
# opts in.
###############################################################################

locals {
  amazon_location_geocoding_enabled = var.enable_amazon_location_geocoding

  amazon_location_place_index_name = var.amazon_location_place_index_name != "" ? var.amazon_location_place_index_name : "${local.name}-geocode"

  amazon_location_place_index_arn = local.amazon_location_geocoding_enabled ? aws_location_place_index.geocoding[0].index_arn : null

  # Geocoding env that routes the demo's GeocodeServer to Amazon Location
  # instead of Nominatim. Geocoding:Providers:Nominatim:Enabled is explicitly
  # forced to "false" here — Nominatim's own default (NominatimProviderConfiguration
  # constructor sets Enabled=true) means it would otherwise stay registered as
  # a failover candidate, and GeocodeCoordinatorService tries providers in
  # order (default provider first, then remaining registered providers when
  # EnableFailover is true). In a no-NAT VPC a subsequent Nominatim attempt
  # would still hang its own ~15.8s outbound-connect timeout before failing —
  # compounding, not fixing, the latency on any amazon-location error. Explicitly
  # disabling it makes a place-index misconfiguration fail fast instead.
  amazon_location_environment = local.amazon_location_geocoding_enabled ? {
    Geocoding__Enabled                                   = "true"
    Geocoding__DefaultProvider                           = "amazon-location"
    Geocoding__Providers__Nominatim__Enabled             = "false"
    Geocoding__Providers__AmazonLocation__Enabled        = "true"
    Geocoding__Providers__AmazonLocation__Region         = data.aws_region.current.name
    Geocoding__Providers__AmazonLocation__PlaceIndexName = local.amazon_location_place_index_name
    Geocoding__Providers__AmazonLocation__UseIamRole     = "true"
    Geocoding__Providers__AmazonLocation__MaxResults     = tostring(var.amazon_location_max_results)
  } : {}
}

# The place index itself. SingleUse (default) matches a live query-only
# GeocodeServer proxy that does not persist results; switch to "Storage" only
# if a future workflow saves/caches geocode results server-side (changes
# Esri/HERE per-request pricing).
resource "aws_location_place_index" "geocoding" {
  count = local.amazon_location_geocoding_enabled ? 1 : 0

  index_name  = local.amazon_location_place_index_name
  data_source = var.amazon_location_data_source
  description = "Honua ${var.environment} geocoding place index (honua-server#2948 — replaces the no-NAT-unreachable Nominatim provider)"

  data_source_configuration {
    intended_use = var.amazon_location_intended_use
  }

  tags = local.tags
}

# Least-privilege Amazon Location geocode grant on the Lambda execution role,
# scoped to this place index's ARN only.
#
# geo:SearchPlaceIndexForText / geo:SearchPlaceIndexForPosition cover forward
# and reverse geocoding (the two operations honua-server#2948 asked for).
# Two more actions are included because the same provider class already calls
# them on other code paths that would otherwise AccessDenied the moment
# they're exercised:
#   - geo:SearchPlaceIndexForSuggestions — the provider's SuggestCoreAsync
#     (GeocodeProviderCapabilities.SupportsSuggest = true for this provider;
#     the demo's GeocodeServer advertises and serves a suggest operation).
#   - geo:DescribePlaceIndex — the provider's CheckHealthCoreAsync (provider
#     health-check probe).
resource "aws_iam_role_policy" "lambda_amazon_location_geocode" {
  count = local.amazon_location_geocoding_enabled ? 1 : 0
  name  = "${local.name}-lambda-amazon-location-geocode"
  role  = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AmazonLocationGeocode"
        Effect = "Allow"
        Action = [
          "geo:SearchPlaceIndexForText",
          "geo:SearchPlaceIndexForPosition",
          "geo:SearchPlaceIndexForSuggestions",
          "geo:DescribePlaceIndex"
        ]
        Resource = [local.amazon_location_place_index_arn]
      }
    ]
  })
}
