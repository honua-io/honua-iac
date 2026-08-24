[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $PlanPath,
  [Parameter(Mandatory = $true)] [string] $StateMetadataPath,
  [Parameter(Mandatory = $true)] [string] $CandidateDigest,
  [Parameter(Mandatory = $true)] [string] $TargetId,
  [Parameter(Mandatory = $true)] [string] $ActorId,
  [Parameter(Mandatory = $true)] [string] $WorkloadIdentityContractDigest,
  [Parameter(Mandatory = $true)] [string] $BackendConfigDigest,
  [Parameter(Mandatory = $true)] [string] $IacRevision,
  [Parameter(Mandatory = $true)] [string] $ProviderLockDigest,
  [Parameter(Mandatory = $true)] [string] $InputDigest,
  [ValidateSet("plan", "apply", "destroy")] [string] $Action = "plan",
  [Parameter(Mandatory = $true)] [datetime] $ExpiresAtUtc,
  [string] $ExpectedStateLineage,
  [long] $ExpectedStateSerial = -1,
  [string] $OutputContractDigest,
  [string] $OutputPath = "-"
)

$ErrorActionPreference = "Stop"

function Assert-Digest([string] $Name, [string] $Value) {
  if ($Value -notmatch '^[0-9a-fA-F]{64}$') { throw "$Name must be a 64-character hexadecimal SHA-256 digest." }
}

Assert-Digest "BackendConfigDigest" $BackendConfigDigest
Assert-Digest "CandidateDigest" $CandidateDigest
Assert-Digest "ProviderLockDigest" $ProviderLockDigest
Assert-Digest "InputDigest" $InputDigest
Assert-Digest "WorkloadIdentityContractDigest" $WorkloadIdentityContractDigest
if ([string]::IsNullOrWhiteSpace($TargetId)) { throw "TargetId must not be empty." }
if ([string]::IsNullOrWhiteSpace($ActorId)) { throw "ActorId must not be empty." }
if ($OutputContractDigest) { Assert-Digest "OutputContractDigest" $OutputContractDigest }
if ($IacRevision -notmatch '^[0-9a-fA-F]{40,64}$') { throw "IacRevision must be a 40- to 64-character hexadecimal revision." }
if ($ExpiresAtUtc.ToUniversalTime() -le [DateTime]::UtcNow) { throw "ExpiresAtUtc must be in the future." }

$planHash = (Get-FileHash -LiteralPath $PlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
$state = Get-Content -LiteralPath $StateMetadataPath -Raw | ConvertFrom-Json
$lineage = [string] $state.lineage
if ($lineage -notmatch '^[0-9a-fA-F-]{36}$') { throw "State metadata must contain a UUID lineage." }
$serialValue = $state.serial
if (-not ($state.PSObject.Properties.Name -contains "serial") -or
    $null -eq $serialValue -or
    ($serialValue -isnot [byte] -and $serialValue -isnot [int16] -and
     $serialValue -isnot [int32] -and $serialValue -isnot [int64])) {
  throw "State metadata must contain an integer serial."
}
$serial = [long] $serialValue
if ($serial -lt 0) { throw "State metadata serial must be zero or greater." }
if ($ExpectedStateLineage -and $ExpectedStateLineage -ne $lineage) { throw "State lineage does not match ExpectedStateLineage." }
if ($ExpectedStateSerial -ge 0 -and $ExpectedStateSerial -ne $serial) { throw "State serial does not match ExpectedStateSerial." }

$contract = [ordered]@{
  schema_version         = "v1"
  action                 = $Action
  candidate_digest       = $CandidateDigest.ToLowerInvariant()
  target_id              = $TargetId
  actor_id               = $ActorId
  workload_identity_contract_digest = $WorkloadIdentityContractDigest.ToLowerInvariant()
  plan_sha256            = $planHash
  backend_config_digest  = $BackendConfigDigest.ToLowerInvariant()
  iac_revision           = $IacRevision.ToLowerInvariant()
  provider_lock_digest   = $ProviderLockDigest.ToLowerInvariant()
  input_digest           = $InputDigest.ToLowerInvariant()
  state_before           = [ordered]@{ lineage = $lineage.ToLowerInvariant(); serial = $serial }
  expires_at_utc         = $ExpiresAtUtc.ToUniversalTime().ToString("o")
  output_contract_digest = if ($OutputContractDigest) { $OutputContractDigest.ToLowerInvariant() } else { $null }
  state_after            = $null
  qualification_status   = "unqualified"
  evidence_scope         = "metadata-only-pre-apply"
}
$json = $contract | ConvertTo-Json -Depth 10
if ($OutputPath -eq "-") { $json } else { Set-Content -LiteralPath $OutputPath -Value $json -Encoding utf8 }
