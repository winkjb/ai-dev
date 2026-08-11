<#
.SYNOPSIS
    This script audits RocketCyber and flags open incidents and isolated devices.

.DESCRIPTION
    Pulls two things directly from RocketCyber's v3 API, across the whole book in one
    paginated call each - no per-account looping, unlike the SentinelOne/Proofpoint
    scripts this otherwise follows the shape of:

    - Open incidents (/incidents?status=open) - RocketCyber's SOC-confirmed findings.
      Unlike SentinelOne, "active threat" doesn't need to be derived from device-level
      rollup fields - status=open is the direct, server-side signal.

    - Isolated devices (/agents?connectivity=isolated) - RocketCyber's term for network
      quarantine (a device automatically isolated after e.g. ransomware activity).

    Omitting accountId on both endpoints returns data for every account at once (per
    RocketCyber's own docs: "If not provided, data will be pulled for all accounts") -
    confirmed live 2026-08-10. That's the whole reason this script has no per-account
    iteration loop the way Export-ProofpointAdmins.ps1/Export-SentinelOneThreats.ps1
    do - there's nothing to loop over. -ExcludedAccounts filters client-side instead,
    on the merged result.

.NOTES
    Confirmed live 2026-08-10: pagination envelope shape ({totalCount, currentPage,
    totalPages, dataCount, data}), field names below, and that the API validates
    strictly - an unrecognized query param and an invalid status value both hard-400,
    rather than being silently ignored - which is what gives confidence status=open
    returning 0 results is a genuine "no open incidents right now" rather than a
    masked failure.

    Incidents and Agents use different field names for the same concept (accountId/
    accountName on incidents, customerId/customerName on agents) - RocketCyber's own
    API inconsistency, not this script's. Both are normalized to AccountName/AccountId
    in the output.

    Incident records also carry description/remediation fields - large freeform text
    blocks (remediation is generic per-detection-type boilerplate, not per-incident
    detail) - deliberately not included in the CSV; Title plus the linked
    AutotaskTicketId/RocketCyberIncidentId are enough to act on, and dumping multi-
    paragraph text into a CSV cell makes it unreadable in Excel.

.EXAMPLE
    .\Export-RocketCyberThreats.ps1

.EXAMPLE
    # Skip specific accounts entirely
    .\Export-RocketCyberThreats.ps1 -ExcludedAccounts "Test Account","Decommissioned Client"
#>

[CmdletBinding()]
param(

    [string[]]$ExcludedAccounts,
    [switch]$LogExclusions = $false

)

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# System settings and variables

$OutputDir = Join-Path $PSScriptRoot "output"
$OutputIncidents = Join-Path $OutputDir "rocketcyber-open-incidents.csv"
$OutputIsolated = Join-Path $OutputDir "rocketcyber-isolated-devices.csv"

# Import functions

. (Join-Path $PSScriptRoot "..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\scripts\Functions-RocketCyber-Common.ps1")

# Import settings and validate output directory

$Settings = Import-Settings -SettingsPath (Join-Path $PSScriptRoot "..\..\data\reference\RocketCyberSettings.txt")
Test-Directory $OutputDir

# ---------------------------------------------------------------------------
# Step 1: Connect
# ---------------------------------------------------------------------------

$Date = Get-Date -Format yyyy-MM-dd
$CountIncidentExclusions = 0
$CountIsolatedExclusions = 0

Write-Host "Connecting to RocketCyber..." -ForegroundColor Cyan
$ApiContext = Set-RocketCyberApiContext -Settings $Settings
$BaseUrl = "https://api-us.rocketcyber.com/v3"

$StartTime = Get-Date

# ---------------------------------------------------------------------------
# Step 2: Open incidents - whole book, one filtered/paginated query.
# ---------------------------------------------------------------------------

Write-Host "Fetching open incidents..." -ForegroundColor Cyan
$OpenIncidents = @(Get-AllRocketCyberResults -BaseUri "$BaseUrl/incidents?status=open" -Headers $ApiContext.Headers)

Write-Host "Found $($OpenIncidents.Count) open incident(s)." -ForegroundColor Green

$IncidentResults = foreach ($Incident in $OpenIncidents) {

    $InExclusion = $ExcludedAccounts -contains $Incident.accountName

    if ($InExclusion) { $CountIncidentExclusions++ }

    if (-not $InExclusion -or $LogExclusions) {

        $Finding = [ordered]@{

            Date              = $Date
            AccountName       = $Incident.accountName
            IncidentId        = $Incident.id
            Title             = $Incident.title
            Status            = $Incident.status
            EventCount        = $Incident.eventCount
            CreatedAt         = $Incident.createdAt
            PublishedAt       = $Incident.publishedAt
            AutotaskTicketId  = $Incident.autotaskTicketId

        }

        if ($LogExclusions) { $Finding.InExclusionGroup = if ($InExclusion) {"Y"} else {$null} }

        [PSCustomObject]$Finding

    }

}

# ---------------------------------------------------------------------------
# Step 3: Isolated devices - whole book, one filtered/paginated query.
# ---------------------------------------------------------------------------

Write-Host "Fetching isolated devices..." -ForegroundColor Cyan
$IsolatedAgents = @(Get-AllRocketCyberResults -BaseUri "$BaseUrl/agents?connectivity=isolated" -Headers $ApiContext.Headers)

Write-Host "Found $($IsolatedAgents.Count) isolated device(s)." -ForegroundColor Green

$IsolatedResults = foreach ($Agent in $IsolatedAgents) {

    $InExclusion = $ExcludedAccounts -contains $Agent.customerName

    if ($InExclusion) { $CountIsolatedExclusions++ }

    if (-not $InExclusion -or $LogExclusions) {

        $Finding = [ordered]@{

            Date            = $Date
            AccountName     = $Agent.customerName
            Hostname        = $Agent.hostname
            IPv4Address     = $Agent.ipv4Address
            OperatingSystem = $Agent.operatingSystem
            Connectivity    = $Agent.connectivity
            LastConnectedAt = $Agent.lastConnectedAt

        }

        if ($LogExclusions) { $Finding.InExclusionGroup = if ($InExclusion) {"Y"} else {$null} }

        [PSCustomObject]$Finding

    }

}

# ---------------------------------------------------------------------------
# Step 4: Complete and output
# ---------------------------------------------------------------------------

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on RocketCyber in $Minutes minutes and $Seconds seconds.`r`n" -ForegroundColor Green

Write-Host "Open incidents: $($IncidentResults.Count) logged, $CountIncidentExclusions excluded." -ForegroundColor Blue
Write-Host "Isolated devices: $($IsolatedResults.Count) logged, $CountIsolatedExclusions excluded." -ForegroundColor Blue

$IncidentResults | Sort-Object AccountName,CreatedAt | Export-Csv -Path $OutputIncidents -NoTypeInformation
$IsolatedResults | Sort-Object AccountName,Hostname | Export-Csv -Path $OutputIsolated -NoTypeInformation
