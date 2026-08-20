<#
.SYNOPSIS
    Analyst: compares a customer's collected Teams activity report
    (../01-collector/Collect-EntraTeamsActivity.ps1's raw snapshot, joined against
    ../01-collector/Collect-EntraGroups.ps1's raw snapshot for CreatedDate) against a staleness
    threshold and flags candidates for disabling. Does not call Graph and does not email - that's
    the collector's and the customer wrapper's job, respectively (see
    ../katz/Invoke-SiteAuditTeams-Disable.ps1).

.DESCRIPTION
    A team is flagged if it's not deleted, was created before the -LessThanDays cutoff (a
    brand-new team hasn't had time to show activity yet, so it gets a pass rather than a false
    "inactive" flag), has had no activity since the cutoff, and isn't in
    data/reference/<Directory>/excluded-teams.csv (shared with
    ../02-analyst/Compare-Teams-Activity.ps1's exclusion list).

    -Testing (default $true, matching the original script's real production default) exists
    only for forward compatibility - no version of this audit, original or ported, has ever
    actually disabled a team via Graph. The original's "real" branch just wrote a status string
    and a Write-Host message referencing a property that didn't exist on the object; it never
    called Graph to disable anything. Since the workspace's current Graph app registration is
    read-only anyway, there's nothing to gate behind the switch today - it's kept so a future
    write-capable version has an on/off toggle already in place, not because it changes behavior
    now. Findings are always just flagged candidates, never a claim that a team was disabled.

.EXAMPLE
    .\Compare-Teams-Disable.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [int]$LessThanDays = 180,

    [string]$ActivityPath,
    [string]$GroupsPath,
    [string]$ExclusionsPath,
    [string]$OutputPath,

    [switch]$IncludeExclusions,
    [switch]$Testing = $true
)

if (-not $ActivityPath)   { $ActivityPath   = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraTeamsActivity.csv" }
if (-not $GroupsPath)     { $GroupsPath     = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraGroups.csv" }
if (-not $ExclusionsPath) { $ExclusionsPath = Join-Path $PSScriptRoot "..\data\reference\$Directory\excluded-teams.csv" }
if (-not $OutputPath)     { $OutputPath     = Join-Path $PSScriptRoot "output\$Directory\Teams-Disable.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$Now = Get-Date
$DateCutoff = $Now.AddDays(-$LessThanDays)

# --- load -----------------------------------------------------------------

$Teams = @(Import-Csv -LiteralPath $ActivityPath -Encoding UTF8)
$Groups = @(Import-Csv -LiteralPath $GroupsPath -Encoding UTF8)
$ExclusionRows = if (Test-Path -LiteralPath $ExclusionsPath) { @(Import-Csv -LiteralPath $ExclusionsPath -Encoding UTF8) } else { @() }
$ExcludedNames = @($ExclusionRows | ForEach-Object { $_.TeamName } | Where-Object { $_ })

$GroupById = @{}
foreach ($Group in $Groups) { $GroupById[$Group.Id] = $Group }

# --- filter/flag -------------------------------------------------------------------

$Candidates = @($Teams.Where({ $_.IsDeleted -ne "True" }))

$ExcludedCount = 0

$Results = foreach ($Team in $Candidates) {

    $GroupInfo = $GroupById[$Team.TeamId]
    $CreatedDate = $GroupInfo.CreatedDate

    # A brand-new team hasn't had time to show activity - skip rather than false-flag.
    if ($CreatedDate -and ([datetime]$CreatedDate) -ge $DateCutoff) { continue }

    $DaysAgo = Get-DaysSince -Value $Team.LastActivityDate -Reference $Now
    $IsStale = ($null -eq $DaysAgo) -or ($DaysAgo -ge $LessThanDays)
    if (-not $IsStale) { continue }

    $IsExcluded = $ExcludedNames -contains $Team.TeamName
    if ($IsExcluded) { $ExcludedCount++ }

    if (-not $IsExcluded -or $IncludeExclusions) {

        $Finding = [ordered]@{
            Date             = $Now.ToString("yyyy-MM-dd")
            TeamName         = $Team.TeamName
            Mail             = $GroupInfo.Mail
            CreatedDate      = $CreatedDate
            LastActivityDate = $Team.LastActivityDate
            DaysAgo          = $DaysAgo
            Issue            = "Last activity more than $LessThanDays days ago"
            Action           = "Disable team"
            ActionTaken      = $null
        }
        if ($IncludeExclusions) { $Finding.Excluded = if ($IsExcluded) { "Y" } else { $null } }
        [PSCustomObject]$Finding

        if ($Testing) { Write-Host "Testing Mode: $($Team.TeamName) would be disabled." -ForegroundColor Yellow }

    }

}

$Results = @($Results | Sort-Object TeamName)

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject $Results

Write-Host "$($Candidates.Count) enabled team(s) evaluated."
Write-Host "$ExcludedCount team(s) excluded via $(Split-Path $ExclusionsPath -Leaf)."
Write-Host "$($Results.Count) stale team(s) flagged."
