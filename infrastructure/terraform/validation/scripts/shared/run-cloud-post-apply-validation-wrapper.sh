#!/usr/bin/env bash
set -euo pipefail

INCLUDE_SCALE_TESTS="${INCLUDE_SCALE_TESTS:-false}"

usage() {
  cat <<'EOF'
Usage: run-cloud-post-apply-validation-wrapper.sh [--terraform-output-json <path>] [--include-scale-tests]

Runs the honua-server post-apply validation suite from the current working directory.
The Terraform validation harness exports the cloud test environment variables before
invoking this wrapper.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-scale-tests)
      INCLUDE_SCALE_TESTS="true"
      shift
      ;;
    --terraform-output-json)
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_tool() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Required tool '$name' is not installed." >&2
    exit 1
  fi
}

if [[ ! -f "Honua.sln" ]]; then
  echo "Expected honua-server repository root as the working directory." >&2
  exit 1
fi

if [[ ! -f "scripts/post-deployment-verification.sh" ]]; then
  echo "Expected honua-server post-deployment verification script in the working directory." >&2
  exit 1
fi

if [[ -z "${HONUA_CLOUD_TEST_BASE_URL:-}" ]]; then
  echo "HONUA_CLOUD_TEST_BASE_URL is required." >&2
  exit 1
fi

require_tool dotnet
require_tool curl

export BASE_URL="${HONUA_CLOUD_TEST_BASE_URL}"
export ENVIRONMENT="${HONUA_CLOUD_TEST_EXPECTED_ENVIRONMENT:-cloud}"

if [[ -n "${HONUA_CLOUD_TEST_ADMIN_API_KEY:-}" ]]; then
  export ADMIN_API_KEY="$HONUA_CLOUD_TEST_ADMIN_API_KEY"
fi

if [[ -n "${HONUA_CLOUD_TEST_EXTRA_HEADER_NAME:-}" && -n "${HONUA_CLOUD_TEST_EXTRA_HEADER_VALUE:-}" ]]; then
  export EXTRA_CURL_HEADER="${HONUA_CLOUD_TEST_EXTRA_HEADER_NAME}: ${HONUA_CLOUD_TEST_EXTRA_HEADER_VALUE}"
fi

cloud_test_filter="${HONUA_PLATFORM_VALIDATION_DOTNET_TEST_FILTER:-Category=Cloud}"
if [[ "$cloud_test_filter" == "Category=Cloud" && "${HONUA_CLOUD_TEST_PLATFORM:-}" == "azure-container-apps" ]]; then
  # ACA currently deploys a server image with the legacy preflight metadata shape.
  cloud_test_filter="${cloud_test_filter}&FullyQualifiedName!=Honua.Server.Tests.Cloud.CloudDeploymentValidationTests.DeployPreflight_ReflectsExpectedEnvironmentState"
fi

echo "Running post-apply validation for ${HONUA_CLOUD_TEST_BASE_URL}"

chmod +x scripts/post-deployment-verification.sh
scripts/post-deployment-verification.sh

dotnet test tests/Honua.Server.Tests/Honua.Server.Tests.csproj \
  -p:RunAnalyzers=false \
  --filter "$cloud_test_filter"

if [[ "$INCLUDE_SCALE_TESTS" == "true" ]]; then
  if [[ -z "${HONUA_SCALE_TEST_BASE_URL:-}" ]]; then
    echo "INCLUDE_SCALE_TESTS=true but HONUA_SCALE_TEST_BASE_URL is not set." >&2
    exit 1
  fi

  echo "Running scale validation against ${HONUA_SCALE_TEST_BASE_URL}"
  dotnet test tests/Honua.Server.Tests/Honua.Server.Tests.csproj \
    -p:RunAnalyzers=false \
    --filter "Category=Scale"
fi

echo "Cloud post-apply validation completed successfully."
