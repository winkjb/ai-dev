<#
.SYNOPSIS
    This script audits SentinelOne agents across all sites and flags active threats.

.DESCRIPTION
    Pulls every site from the SentinelOne console, then queries agents in batches
    across all queued sites at once (via a comma-joined siteIds filter) using
    server-side filters for active threats and network quarantine, instead of
    pulling every agent at every site and filtering client-side.

.NOTES
    Validated 2026-08-10 against a live run: field-by-field diff against a reference
    CSV from the original per-site full-iteration version found 0 missing, 0 extra,
    0 field mismatches across all flagged agents, in ~9 seconds vs. ~4.5 minutes for
    528 sites. Also confirmed empirically that infected=true and activeThreats__gt=0
    return identical result sets (matches the API's own description of "infected" as
    "at least one active threat") - only activeThreats__gt=0 is queried below, not both,
    since infected added no additional coverage in that test. Confirmed the API
    validates query params strictly (an unrecognized param gets a hard 400, not a
    silent no-op), which is what gives confidence activeThreats__gt/
    networkQuarantineEnabled are genuinely recognized filters and not coincidentally
    always-empty ones.

.EXAMPLE
    .\Export-SentinelOneThreats.ps1

.EXAMPLE
    # Skip specific sites entirely
    .\Export-SentinelOneThreats.ps1 -ExcludedSites "Decommissioned Site","Test Lab"
#>

[CmdletBinding()]
param(

    [string]$Console = "usea1-swprd5.sentinelone.net",
    [string[]]$ExcludedSites,
    [switch]$LogExclusions = $false

)

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# System settings and variables

$OutputDir = Join-Path $PSScriptRoot ".\data\raw"
$OutputSummary = Join-Path $OutputDir "sentinelonethreats-all.csv"

# Number of site IDs per batched agents query - keeps the comma-joined siteIds
# query string well under URL-length limits (528 sites joined in one request
# would run ~10,000 characters).
$ChunkSize = 50

# Import functions

. (Join-Path $PSScriptRoot "..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\scripts\Functions-SentinelOne-Common.ps1")

# Import settings and validate output directory

$Settings = Import-Settings -SettingsPath (Join-Path $PSScriptRoot "..\..\data\reference\SentinelOneSettings.txt")
Test-Directory $OutputDir

# ---------------------------------------------------------------------------
# Step 1: Get all sites
# ---------------------------------------------------------------------------

# Script settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$i = 0
$CountInactive = 0
$CountAudited = 0
$CountExclusions = 0
$CountResults = 0

# Import settings and set API context

Write-Host "Connecting to SentinelOne..." -ForegroundColor Cyan
$ApiContext = Set-S1ApiContext -Settings $Settings

# Start processing

$StartTime = Get-Date

# Get sites and page results

$Uri = "https://$Console/web/api/v2.1/sites"
$Sites = (Get-AllS1Results -BaseUri $Uri -Headers $ApiContext.Headers).sites

if (-not $Sites -or $Sites.Count -eq 0) {
    Write-Error "No sites returned. Check credentials and API access scope."
    return
}

$CountSites = @($Sites).count

Write-Host "Found $CountSites site(s)." -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 2: Classify sites - active/inactive, excluded/not. Cheap, so still done
# per-site; it's the agent lookup below that's batched.
# ---------------------------------------------------------------------------

$SitesToAudit = foreach ($Site in $Sites) {

    $i++

    # Inactive sites have no live agent data worth auditing - always skipped,
    # regardless of -ExcludedSites (this isn't a user exclusion, the site is
    # simply not in service).

    if ($Site.state -ne "active") {
        $CountInactive++
        Write-Host "[$i/$CountSites] Skipping site: $($Site.name) (not active)" -ForegroundColor DarkGray
        continue
    }

    # Identify exclusions

    $InExclusion = $ExcludedSites -contains $Site.name

    if ($InExclusion) {

        $CountExclusions++
        Write-Host "[$i/$CountSites] Skipping site: $($Site.name) (excluded)" -ForegroundColor DarkGray

    } else {

        Write-Host "[$i/$CountSites] Queuing site: $($Site.name)" -ForegroundColor Yellow

    }

    if (-not $InExclusion -or $LogExclusions) {

        $CountAudited++
        [PSCustomObject]@{ Id = $Site.id; Name = $Site.name; InExclusion = $InExclusion }

    }

}

# @() guards against PowerShell silently unwrapping a 1-element array to a bare
# object, which would break the chunking/count logic below.
$SitesToAudit = @($SitesToAudit)
$SiteById = @{}
foreach ($s in $SitesToAudit) { $SiteById[$s.Id] = $s }

# ---------------------------------------------------------------------------
# Step 3: Query flagged agents across all queued sites, batched - server-side
# filters instead of pulling every agent and checking client-side.
# ---------------------------------------------------------------------------

$FlaggedAgents = @{}

for ($ChunkStart = 0; $ChunkStart -lt $SitesToAudit.Count; $ChunkStart += $ChunkSize) {

    $ChunkEnd = [Math]::Min($ChunkStart + $ChunkSize - 1, $SitesToAudit.Count - 1)
    $ChunkIds = $SitesToAudit[$ChunkStart..$ChunkEnd].Id
    $SiteIdList = ($ChunkIds -join ",")

    Write-Host "Querying agents for sites $($ChunkStart + 1)-$($ChunkEnd + 1) of $($SitesToAudit.Count)..." -ForegroundColor Cyan

    $ThreatAgents = @(Get-AllS1Results -BaseUri "https://$Console/web/api/v2.1/agents?siteIds=$SiteIdList&activeThreats__gt=0" -Headers $ApiContext.Headers)
    $QuarantineAgents = @(Get-AllS1Results -BaseUri "https://$Console/web/api/v2.1/agents?siteIds=$SiteIdList&networkQuarantineEnabled=true" -Headers $ApiContext.Headers)

    foreach ($Agent in ($ThreatAgents + $QuarantineAgents)) {
        if ($Agent -and $Agent.id) { $FlaggedAgents[$Agent.id] = $Agent }
    }

}

# ---------------------------------------------------------------------------
# Step 4: Build findings
# ---------------------------------------------------------------------------

$Results = foreach ($Agent in $FlaggedAgents.Values) {

    $CountResults++
    $Site = $SiteById[$Agent.siteId]

    $Finding = [ordered]@{

        Date          = $Date
        SiteName      = $Site.Name
        ComputerName  = $Agent.computerName
        IsActive      = $Agent.isActive
        IsUpToDate    = $Agent.isUpToDate
        Infected      = $Agent.infected
        ActiveThreats = $Agent.activeThreats
        Quarantine    = $Agent.networkQuarantineEnabled

    }

    if ($LogExclusions) { $Finding.InExclusionGroup = if ($Site.InExclusion) {"Y"} else {$null} }

    [PSCustomObject]$Finding

}

# ---------------------------------------------------------------------------
# Step 5: Complete and output
# ---------------------------------------------------------------------------

# End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on SentinelOne agent(s) in $Minutes minutes and $Seconds seconds.`r`n" -ForegroundColor Green

Write-Host "Sites: $CountSites total, $CountAudited audited, $CountInactive not active, $CountExclusions excluded." -ForegroundColor Blue
Write-Host "Threats: $CountResults logged." -ForegroundColor Blue

$Results | Sort-Object SiteName,ComputerName | Export-Csv -Path $OutputSummary -NoTypeInformation
