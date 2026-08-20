<#
.SYNOPSIS
    Analyst: compares a customer's collected SharePoint usage report
    (../01-collector/Collect-EntraSharepointActivity.ps1's raw snapshot) against a staleness
    threshold and flags candidates for disabling. Does not call Graph and does not email -
    that's the collector's and the customer wrapper's job, respectively (see
    ../katz/Invoke-SiteAuditSharepoint-Disable.ps1).

.DESCRIPTION
    A site is a candidate if it's not deleted, isn't a "Team Channel"/"* Search Center" system
    site, isn't Team-backed (IsTeamBacked=Y in the raw snapshot - a Team's SharePoint site is
    ../02-analyst/Compare-Teams-Disable.ps1's concern, not this one's, so it's never
    double-flagged here), was created before the -LessThanDays cutoff (a brand-new site hasn't
    had time to show activity yet, so it gets a pass), and has had no activity since the
    cutoff. Sites listed in data/reference/<Directory>/excluded-sharepoint-sites-disable.csv
    (matched by Name) are dropped by default - pass -IncludeExclusions to keep them. This is a
    separate list from ../02-analyst/Compare-Sharepoint-Activity.ps1's
    excluded-sharepoint-sites-activity.csv - matches the original katz wrapper's own local
    $ExcludedSites baseline ("Project Web App", "Team Site"), which only ever applied to this
    disable audit, not the activity report.

    -Testing (default $true, matching the original script's real production default) exists
    only for forward compatibility - no version of this audit, original or ported, has ever
    actually disabled a site via Graph, and the workspace's current Graph app registration is
    read-only anyway. Findings are always just flagged candidates, never a claim that a site
    was disabled.

.EXAMPLE
    .\Compare-Sharepoint-Disable.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [int]$LessThanDays = 180,

    [string]$RawPath,
    [string]$ExclusionsPath,
    [string]$OutputPath,

    [switch]$IncludeExclusions,
    [switch]$Testing = $true
)

if (-not $RawPath)        { $RawPath        = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraSharepointActivity.csv" }
if (-not $ExclusionsPath) { $ExclusionsPath = Join-Path $PSScriptRoot "..\data\reference\$Directory\excluded-sharepoint-sites-disable.csv" }
if (-not $OutputPath)     { $OutputPath     = Join-Path $PSScriptRoot "output\$Directory\Sharepoint-Disable.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$Now = Get-Date
$DateCutoff = $Now.AddDays(-$LessThanDays)

# --- load -----------------------------------------------------------------

$Sites = @(Import-Csv -LiteralPath $RawPath -Encoding UTF8)
$ExclusionRows = if (Test-Path -LiteralPath $ExclusionsPath) { @(Import-Csv -LiteralPath $ExclusionsPath -Encoding UTF8) } else { @() }
$ExcludedNames = @($ExclusionRows | ForEach-Object { $_.Name } | Where-Object { $_ })

# --- filter/flag -------------------------------------------------------------------

$InScope = @($Sites.Where({
    ($_.IsDeleted -ne "True") -and
    ($_.RootWebTemplate -ne "Team Channel") -and
    ($_.RootWebTemplate -notlike "* Search Center") -and
    ($_.IsTeamBacked -ne "Y")
}))

$ExcludedCount = 0
$CountTeamBacked = @($Sites.Where({ $_.IsTeamBacked -eq "Y" })).Count

$Results = foreach ($Site in $InScope) {

    if ($Site.CreatedDate -and ([datetime]$Site.CreatedDate) -ge $DateCutoff) { continue }

    $DaysAgo = Get-DaysSince -Value $Site.LastActivityDate -Reference $Now
    $IsStale = ($null -eq $DaysAgo) -or ($DaysAgo -ge $LessThanDays)
    if (-not $IsStale) { continue }

    $IsExcluded = $ExcludedNames -contains $Site.Name
    if ($IsExcluded) { $ExcludedCount++ }

    if (-not $IsExcluded -or $IncludeExclusions) {

        $StorageUsedGb = [math]::Round([double]$Site.StorageUsedBytes / 1000000000, 2)

        $Finding = [ordered]@{
            Date             = $Now.ToString("yyyy-MM-dd")
            SiteName         = $Site.Name
            WebUrl           = $Site.WebUrl
            CreatedDate      = $Site.CreatedDate
            FileCount        = $Site.FileCount
            StorageUsedGb    = $StorageUsedGb
            LastActivityDate = $Site.LastActivityDate
            DaysAgo          = $DaysAgo
            Issue            = "Last activity more than $LessThanDays days ago"
            Action           = "Disable site"
            ActionTaken      = $null
        }
        if ($IncludeExclusions) { $Finding.Excluded = if ($IsExcluded) { "Y" } else { $null } }
        [PSCustomObject]$Finding

        if ($Testing) { Write-Host "Testing Mode: $($Site.Name) would be disabled." -ForegroundColor Yellow }

    }

}

$Results = @($Results | Sort-Object SiteName)

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject $Results

Write-Host "$($InScope.Count) in-scope site(s) evaluated ($CountTeamBacked Team-backed site(s) excluded)."
Write-Host "$ExcludedCount site(s) excluded via $(Split-Path $ExclusionsPath -Leaf)."
Write-Host "$($Results.Count) stale site(s) flagged."
