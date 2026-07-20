<#
.SYNOPSIS
    Discovers every FortiGate client/site under data/reference/customers and runs the
    hit-count and security-profile collectors against each one.

.DESCRIPTION
    Walks data/reference/customers/**/CustomerSettings.txt recursively. For each one
    found, decrypts it via Import-Settings and checks the NetworkDevice field -
    only sites where NetworkDevice is "FortiGate" are assessed (this is the FortiGate
    discovery wrapper; SonicWall/WatchGuard get their own under scripts/sonicwall,
    scripts/watchguard once those exist). Onboarding a new client/site is then just
    "drop a CustomerSettings.txt in the right folder" - no script or scheduler changes.

    Each collector script is invoked in-process (not as a child process) - a script
    that fails and calls exit 1 only ends its own scope this way, not the whole
    discovery run, so one unreachable firewall doesn't skip every client after it.
    Per-site/per-report failures are caught and recorded in the summary table rather
    than stopping the run.

    Output lands under data/raw/customers/<client>/<site>/fortigate_assessment_<timestamp>/,
    mirroring the same relative path each site has under data/reference/customers/ - so
    a site's raw exports and its settings file are easy to correlate. Both reports for a
    given site/run share the one timestamped folder rather than landing in two separate
    ones a few seconds apart - they're one assessment, not two.

.EXAMPLE
    # Run both reports against every discovered FortiGate site
    .\Invoke-FortiGateDiscovery.ps1

.EXAMPLE
    # Exclude disabled policies everywhere, and only run the security-profile audit
    .\Invoke-FortiGateDiscovery.ps1 -ExcludeDisabled -SkipHitCounts
#>

[CmdletBinding()]
param(
    [string]$CustomersRoot = (Join-Path $PSScriptRoot "..\..\data\reference\customers"),

    [string]$RawDataRoot = (Join-Path $PSScriptRoot "..\..\data\raw\customers"),

    [switch]$ExcludeDisabled,

    [switch]$SkipHitCounts,

    [switch]$SkipSecurityProfiles,

    # Passed through to Import-Settings for every site; leave blank to use its
    # own default/env-var resolution (see scripts/VA-Functions-Common.ps1).
    [string]$KeyPath
)

$CommonScript = Join-Path $PSScriptRoot "..\..\..\..\scripts\VA-Functions-Common.ps1"
if (-not (Test-Path -LiteralPath $CommonScript)) {
    Write-Error "Shared functions script not found: $CommonScript"
    exit 1
}
. $CommonScript

$CustomersRoot = [System.IO.Path]::GetFullPath($CustomersRoot).TrimEnd('\')
$RawDataRoot = [System.IO.Path]::GetFullPath($RawDataRoot).TrimEnd('\')

if (-not (Test-Path -LiteralPath $CustomersRoot)) {
    Write-Error "Customers root not found: $CustomersRoot"
    exit 1
}

$HitCountsScript = Join-Path $PSScriptRoot "Get-FortiGateHitCounts.ps1"
$SecurityProfilesScript = Join-Path $PSScriptRoot "Get-FortiGateSecurityProfiles.ps1"

$SettingsFiles = Get-ChildItem -Path $CustomersRoot -Filter "CustomerSettings.txt" -Recurse -File

if ($SettingsFiles.Count -eq 0) {
    Write-Host "No CustomerSettings.txt files found under $CustomersRoot" -ForegroundColor Yellow
    exit 0
}

Write-Host "Discovered $($SettingsFiles.Count) settings file(s) under $CustomersRoot" -ForegroundColor Cyan

$Results = foreach ($SettingsFile in $SettingsFiles) {

    # Path relative to the customers root (e.g. "aqs\hq") - identifies the site in the
    # summary and gives the raw-output folder the same shape as the settings folder.
    $RelativePath = $SettingsFile.DirectoryName.Substring($CustomersRoot.Length).Trim('\')
    $SiteLabel = $RelativePath -replace '\\', '/'

    Write-Host "`n=== $SiteLabel ===" -ForegroundColor Cyan

    $ImportParams = @{ SettingsPath = $SettingsFile.FullName }
    if ($KeyPath) { $ImportParams["KeyPath"] = $KeyPath }

    try {
        $CustomerSettings = Import-Settings @ImportParams
    }
    catch {
        Write-Host "  Skipped - failed to decrypt settings: $($_.Exception.Message)" -ForegroundColor Red
        [PSCustomObject]@{ Site = $SiteLabel; Report = "-"; Status = "Error"; Detail = "Decrypt failed: $($_.Exception.Message)" }
        continue
    }

    if ($CustomerSettings.NetworkDevice -ne "FortiGate") {
        Write-Host "  Skipped - NetworkDevice is '$($CustomerSettings.NetworkDevice)', not FortiGate." -ForegroundColor DarkGray
        [PSCustomObject]@{ Site = $SiteLabel; Report = "-"; Status = "Skipped"; Detail = "NetworkDevice = $($CustomerSettings.NetworkDevice)" }
        continue
    }

    # One shared output folder per site per run - both reports are really one
    # assessment, so they land together rather than in two separately-timestamped
    # folders a few seconds apart.
    $OutPath = Join-Path $RawDataRoot "$RelativePath\fortigate_assessment_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

    if (-not $SkipHitCounts) {
        try {
            # Piped to Out-Host so the called script's own Format-Table output renders
            # immediately as a complete sequence, instead of leaking into $Results below
            # (which would interleave two Format-Table streams and break console rendering).
            & $HitCountsScript -CustomerSettingsPath $SettingsFile.FullName -ExcludeDisabled:$ExcludeDisabled -ExportCsv -OutputPath $OutPath | Out-Host
            if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
                [PSCustomObject]@{ Site = $SiteLabel; Report = "HitCounts"; Status = "Error"; Detail = "Exited with code $LASTEXITCODE" }
            }
            else {
                [PSCustomObject]@{ Site = $SiteLabel; Report = "HitCounts"; Status = "OK"; Detail = $OutPath }
            }
        }
        catch {
            Write-Host "  Hit-counts run failed: $($_.Exception.Message)" -ForegroundColor Red
            [PSCustomObject]@{ Site = $SiteLabel; Report = "HitCounts"; Status = "Error"; Detail = $_.Exception.Message }
        }
    }

    if (-not $SkipSecurityProfiles) {
        try {
            & $SecurityProfilesScript -CustomerSettingsPath $SettingsFile.FullName -ExcludeDisabled:$ExcludeDisabled -ExportCsv -OutputPath $OutPath | Out-Host
            if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
                [PSCustomObject]@{ Site = $SiteLabel; Report = "SecurityProfiles"; Status = "Error"; Detail = "Exited with code $LASTEXITCODE" }
            }
            else {
                [PSCustomObject]@{ Site = $SiteLabel; Report = "SecurityProfiles"; Status = "OK"; Detail = $OutPath }
            }
        }
        catch {
            Write-Host "  Security-profiles run failed: $($_.Exception.Message)" -ForegroundColor Red
            [PSCustomObject]@{ Site = $SiteLabel; Report = "SecurityProfiles"; Status = "Error"; Detail = $_.Exception.Message }
        }
    }
}

Write-Host "`n--- Discovery Run Summary ---" -ForegroundColor Yellow
$Results | Format-Table -AutoSize -Wrap

$ErrorCount = ($Results | Where-Object { $_.Status -eq "Error" }).Count
if ($ErrorCount -gt 0) {
    Write-Host "`n$ErrorCount site/report run(s) failed - see Detail column above." -ForegroundColor Red
}
