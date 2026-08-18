<#
.SYNOPSIS
    Analyst: shapes a customer's collected Teams activity report
    (../01-collector/Collect-EntraTeamsActivity.ps1's raw snapshot, joined against
    ../01-collector/Collect-EntraGroups.ps1's raw snapshot for CreatedDate) into a flat report.
    Does not call Graph and does not email - that's the collector's and the customer wrapper's
    job, respectively (see ../katz/Invoke-SiteAuditTeams-Activity.ps1).

.DESCRIPTION
    Excludes deleted teams always, and teams listed in
    data/reference/<Directory>/excluded-teams.csv (matched by TeamName) by default - pass
    -IncludeExclusions to keep them, marked via an Excluded column (only appears in the output
    at all when -IncludeExclusions is used, matching ../02-analyst/Compare-Groups-Temp.ps1's
    IsExcluded convention).

    Reporting-only - no baseline/threshold, just the current activity snapshot per team. Compare
    against ../02-analyst/Compare-Teams-Disable.ps1 for the flagged/stale-team version of this
    same data.

.EXAMPLE
    .\Compare-Teams-Activity.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [string]$ActivityPath,
    [string]$GroupsPath,
    [string]$ExclusionsPath,
    [string]$OutputPath,

    [switch]$IncludeExclusions
)

if (-not $ActivityPath)   { $ActivityPath   = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraTeamsActivity.csv" }
if (-not $GroupsPath)     { $GroupsPath     = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraGroups.csv" }
if (-not $ExclusionsPath) { $ExclusionsPath = Join-Path $PSScriptRoot "..\data\reference\$Directory\excluded-teams.csv" }
if (-not $OutputPath)     { $OutputPath     = Join-Path $PSScriptRoot "output\$Directory\Teams-Activity.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$Now = Get-Date

# --- load -----------------------------------------------------------------

$Teams = @(Import-Csv -LiteralPath $ActivityPath -Encoding UTF8)
$Groups = @(Import-Csv -LiteralPath $GroupsPath -Encoding UTF8)
$ExclusionRows = if (Test-Path -LiteralPath $ExclusionsPath) { @(Import-Csv -LiteralPath $ExclusionsPath -Encoding UTF8) } else { @() }
$ExcludedNames = @($ExclusionRows | ForEach-Object { $_.TeamName } | Where-Object { $_ })

$GroupById = @{}
foreach ($Group in $Groups) { $GroupById[$Group.Id] = $Group }

# --- filter/shape -------------------------------------------------------------------

$Active = @($Teams.Where({ $_.IsDeleted -ne "True" }))

$ExcludedCount = 0

$Results = foreach ($Team in $Active) {

    $IsExcluded = $ExcludedNames -contains $Team.TeamName
    if ($IsExcluded) { $ExcludedCount++ }

    if (-not $IsExcluded -or $IncludeExclusions) {

        $GroupInfo = $GroupById[$Team.TeamId]

        $Finding = [ordered]@{
            TeamName         = $Team.TeamName
            ActiveUsers      = $Team.ActiveUsers
            ActiveChannels   = $Team.ActiveChannels
            PostMessages     = $Team.PostMessages
            ReplyMessages    = $Team.ReplyMessages
            CreatedDate      = $GroupInfo.CreatedDate
            LastActivityDate = $Team.LastActivityDate
            DaysAgo          = Get-DaysSince -Value $Team.LastActivityDate -Reference $Now
        }
        if ($IncludeExclusions) { $Finding.Excluded = if ($IsExcluded) { "Y" } else { $null } }
        [PSCustomObject]$Finding

    }

}

$Results = @($Results | Sort-Object TeamName)

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject $Results

Write-Host "$($Active.Count) enabled team(s) audited."
Write-Host "$ExcludedCount team(s) excluded via $(Split-Path $ExclusionsPath -Leaf)."
Write-Host "$($Results.Count) row(s) written to $OutputPath"
