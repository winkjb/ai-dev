<#
.SYNOPSIS
    Collector: pulls the Teams activity report via Graph API - raw and unfiltered, no
    interpretation. Writes one raw snapshot to data/raw/<Directory>/EntraTeamsActivity.csv.
    Analyst scripts (../02-analyst/Compare-Teams-Activity.ps1, ../02-analyst/Compare-Teams-Disable.ps1)
    read this file rather than calling Graph directly.

.DESCRIPTION
    Does NOT re-pull group metadata (CreatedDateTime/Mail/DisplayName) - a Team's ID is its
    underlying Unified Group's ID, so both Analyst scripts join this file against
    ../01-collector/Collect-EntraGroups.ps1's existing EntraGroups.csv snapshot instead of a
    third independent groups pull. Group data already covers everything needed here
    (Id/DisplayName/Mail/CreatedDate), so this isn't the "field needs differ" case that
    justifies an independent pull elsewhere in this workspace (see Collect-EntraLicenses.ps1's
    .DESCRIPTION) - it's the "same fields, genuinely shared" case (see Collect-EntraUsers.ps1's).

    -ReportingDays selects the Graph report's aggregation window (7/30/90/180 are the only
    values Graph accepts) - defaults to 180, matching both original scripts' real production
    value (the retired SiteAuditTeams-Activity-Wrapper.ps1/SiteAuditTeams-Disable-Default.ps1's
    hardcoded period). This is a genuine collection-time choice, not something an Analyst can
    defer - Graph pre-aggregates these metrics per period, they aren't raw daily rows that could
    be re-aggregated after the fact.

.EXAMPLE
    .\Collect-EntraTeamsActivity.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [ValidateSet(7, 30, 90, 180)]
    [int]$ReportingDays = 180,

    [string]$SettingsPath,
    [string]$OutputPath
)

if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot "..\data\reference\$Directory\M365Settings.txt" }
if (-not $OutputPath)   { $OutputPath   = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraTeamsActivity.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-M365-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$StartTime = Get-Date

$CustomerSettings = Import-Settings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

Write-Host "Fetching Teams activity report (D$ReportingDays)..." -ForegroundColor Cyan
$Uri = "https://graph.microsoft.com/v1.0/reports/getTeamsTeamActivityDetail(period='D$ReportingDays')"
$Teams = Invoke-RestMethod -Uri $Uri -Headers $Headers | ConvertFrom-Csv -Delimiter ','

$Rows = foreach ($Team in $Teams) {
    [PSCustomObject]@{
        TeamId           = $Team.'Team Id'
        TeamName         = $Team.'Team Name'
        IsDeleted        = $Team.'Is Deleted'
        ActiveUsers      = $Team.'Active Users'
        ActiveChannels   = $Team.'Active Channels'
        PostMessages     = $Team.'Post Messages'
        ReplyMessages    = $Team.'Reply Messages'
        LastActivityDate = $Team.'Last Activity Date'
    }
}

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject @($Rows)

$TotalSeconds = ((Get-Date) - $StartTime).TotalSeconds
Write-Host ("Wrote {0} team(s) to {1} in {2:N0}s" -f $Rows.Count, $OutputPath, $TotalSeconds) -ForegroundColor Green
