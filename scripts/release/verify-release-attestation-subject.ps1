[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("win32-x64")]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [string]$ContractPath,

  [Parameter(Mandatory = $true)]
  [string]$SubjectPath,

  [Parameter(Mandatory = $true)]
  [string]$ReleaseTag
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")

function Get-RepoAbsolutePath([string]$Path) {
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Assert-File([string]$Path, [string]$Name) {
  $absolute = Get-RepoAbsolutePath $Path
  if (-not (Test-Path -LiteralPath $absolute -PathType Leaf)) {
    throw "$Name must be a file: $Path"
  }
  (Resolve-Path -LiteralPath $absolute -ErrorAction Stop).Path
}

function Test-HasProperty([object]$Object, [string]$Name) {
  $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Get-RequiredProperty([object]$Object, [string]$Name, [string]$Context) {
  if (-not (Test-HasProperty $Object $Name)) {
    throw "$Context must define $Name."
  }
  $Object.$Name
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
  if ($Expected -ne $Actual) {
    throw "$Message Expected '$Expected', got '$Actual'."
  }
}

function Assert-JsonBoolean([object]$Object, [string]$Name, [bool]$Expected, [string]$Context) {
  $value = Get-RequiredProperty $Object $Name $Context
  if ($value -isnot [bool]) {
    throw "$Context $Name must be a JSON boolean."
  }
  Assert-Equal $Expected ([bool]$value) "$Context $Name must match the contract."
}

function Get-Sha256([string]$Path) {
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$contractResolved = Assert-File $ContractPath "ContractPath"
$subjectResolved = Assert-File $SubjectPath "SubjectPath"
$contract = Get-Content -Raw -LiteralPath $contractResolved | ConvertFrom-Json

Assert-Equal 1 ([int]$contract.schemaVersion) "Attestation contract schemaVersion should be 1."
Assert-Equal "subversionr.release.github-attestation-contract.win32-x64.v1" ([string]$contract.schema) "Attestation contract schema must match."
Assert-JsonBoolean $contract "publicReadinessClaim" $false "Attestation contract"
Assert-Equal $Target ([string]$contract.target) "Attestation contract target must match."

$release = Get-RequiredProperty $contract "release" "Attestation contract"
Assert-Equal $ReleaseTag ([string](Get-RequiredProperty $release "tag" "Attestation contract release")) "Release tag must match the attestation contract."
Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/releases/tag/$ReleaseTag" ([string](Get-RequiredProperty $release "url" "Attestation contract release")) "Release URL must match the attestation contract."

$subject = Get-RequiredProperty $contract "subject" "Attestation contract"
$subjectName = [string](Get-RequiredProperty $subject "name" "Attestation contract subject")
$subjectSha256 = [string](Get-RequiredProperty $subject "sha256" "Attestation contract subject")
Assert-Equal $subjectName (Split-Path -Leaf $subjectResolved) "Attestation subject name must match the downloaded file."
Assert-Equal ([int64](Get-RequiredProperty $subject "size" "Attestation contract subject")) ([int64](Get-Item -LiteralPath $subjectResolved).Length) "Attestation subject size must match current bytes."
Assert-Equal $subjectSha256 (Get-Sha256 $subjectResolved) "Attestation subject SHA256 must match current bytes."

$attestation = Get-RequiredProperty $contract "attestation" "Attestation contract"
Assert-Equal "github-artifact-attestations" ([string](Get-RequiredProperty $attestation "provider" "Attestation contract attestation")) "Attestation provider must match."
Assert-Equal "actions/attest-build-provenance@v4" ([string](Get-RequiredProperty $attestation "action" "Attestation contract attestation")) "Attestation action must match."
Assert-Equal "0f67c3f4856b2e3261c31976d6725780e5e4c373" ([string](Get-RequiredProperty $attestation "actionDigest" "Attestation contract attestation")) "Attestation action digest must match."
Assert-Equal "https://slsa.dev/provenance/v1" ([string](Get-RequiredProperty $attestation "predicateType" "Attestation contract attestation")) "Attestation predicate type must match."

$workflow = Get-RequiredProperty $contract "workflow" "Attestation contract"
Assert-Equal ".github/workflows/attest-release-vsix.yml" ([string](Get-RequiredProperty $workflow "path" "Attestation contract workflow")) "Attestation workflow path must match."
Assert-Equal "ubuntu-24.04" ([string](Get-RequiredProperty $workflow "runner" "Attestation contract workflow")) "Attestation workflow runner must match."
Assert-Equal "workflow_dispatch" ([string](Get-RequiredProperty $workflow "trigger" "Attestation contract workflow")) "Attestation workflow trigger must match."
$requiredPermissions = @($workflow.requiredPermissions | ForEach-Object { [string]$_ })
$expectedPermissions = @("contents: read", "id-token: write", "attestations: write")
Assert-Equal $expectedPermissions.Count $requiredPermissions.Count "Attestation workflow must record exactly the required permissions."
foreach ($permission in $expectedPermissions) {
  Assert-Equal 1 @($requiredPermissions | Where-Object { $_ -eq $permission }).Count "Attestation workflow permission '$permission' must be recorded exactly once."
}

$verification = Get-RequiredProperty $contract "verificationPolicy" "Attestation contract"
Assert-Equal "Hitsuki-Ban/SubversionR" ([string](Get-RequiredProperty $verification "repository" "Attestation verification policy")) "Attestation verification repository must match."
Assert-Equal "Hitsuki-Ban/SubversionR/.github/workflows/attest-release-vsix.yml" ([string](Get-RequiredProperty $verification "signerWorkflow" "Attestation verification policy")) "Attestation signer workflow must match."
Assert-Equal "https://slsa.dev/provenance/v1" ([string](Get-RequiredProperty $verification "predicateType" "Attestation verification policy")) "Attestation verification predicate type must match."
Assert-JsonBoolean $verification "bundleRequired" $true "Attestation verification policy"
Assert-JsonBoolean $verification "sourceRefRequired" $true "Attestation verification policy"
Assert-JsonBoolean $verification "sourceDigestRequired" $true "Attestation verification policy"
Assert-JsonBoolean $verification "signerDigestRequired" $true "Attestation verification policy"
Assert-JsonBoolean $verification "denySelfHostedRunners" $true "Attestation verification policy"
Assert-Equal "json" ([string](Get-RequiredProperty $verification "format" "Attestation verification policy")) "Attestation verification format must match."

Write-Host "Verified SubversionR release attestation subject for $Target at $subjectResolved."
