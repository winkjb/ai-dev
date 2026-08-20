<#
.SYNOPSIS
    Analyst: compares a customer's collected Entra group list (../01-collector/Collect-EntraGroups.ps1's
    raw snapshot) against the internal "looks temporary" naming baseline and writes flagged findings.
    Does not call Graph and does not email - that's the collector's and the customer wrapper's job,
    respectively (see ../katz/Invoke-GroupAudit-Temp.ps1).

.DESCRIPTION
    A group is flagged if its DisplayName or Mail contains "test" or "temp" (case-insensitive),
    except names containing "Templates" (avoids false-positiving on legitimate naming) - the same
    heuristic the original katz/GroupAudit-TempGroups.ps1 used.

    Groups listed in data/reference/<Directory>/excluded-temp-groups.csv (matched by DisplayName or
    Mail) are dropped from the findings by default. Pass -IncludeExclusions to keep them in the
    output instead, marked via an IsExcluded column - that column only appears in the output at
    all when -IncludeExclusions is used, since it would otherwise be blank on every row.

.EXAMPLE
    .\Compare-Groups-Temp.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [string]$RawPath,
    [string]$ExclusionsPath,
    [string]$OutputPath,
    [switch]$IncludeExclusions
)

if (-not $RawPath)        { $RawPath        = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraGroups.csv" }
if (-not $ExclusionsPath) { $ExclusionsPath = Join-Path $PSScriptRoot "..\data\reference\$Directory\excluded-temp-groups.csv" }
if (-not $OutputPath)     { $OutputPath     = Join-Path $PSScriptRoot "output\$Directory\GroupAudit-Temp.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$Now = Get-Date

# --- load -----------------------------------------------------------------

$Groups = @(Import-Csv -LiteralPath $RawPath -Encoding UTF8)
$ExclusionRows = if (Test-Path -LiteralPath $ExclusionsPath) { @(Import-Csv -LiteralPath $ExclusionsPath -Encoding UTF8) } else { @() }
$ExcludedNames = @($ExclusionRows | ForEach-Object { $_.DisplayName; $_.Mail } | Where-Object { $_ })

# --- flag -------------------------------------------------------------------

$Flagged = @($Groups.Where({
    (($_.DisplayName -like "*test*") -or ($_.DisplayName -like "*temp*") -or ($_.Mail -like "*test*") -or ($_.Mail -like "*temp*")) `
    -and ($_.DisplayName -notlike "*Templates*")
}))

$ExcludedCount = 0

$Results = foreach ($Group in $Flagged) {

    $IsExcluded = ($ExcludedNames -contains $Group.DisplayName) -or ($ExcludedNames -contains $Group.Mail)
    if ($IsExcluded) { $ExcludedCount++ }

    if (-not $IsExcluded -or $IncludeExclusions) {
        $Finding = [ordered]@{
            Date        = $Now.ToString("yyyy-MM-dd")
            DisplayName = $Group.DisplayName
            Email       = $Group.Mail
            CreatedDate = $Group.CreatedDate
            DaysAgo     = Get-DaysSince -Value $Group.CreatedDate -Reference $Now
            GroupType   = $Group.GroupTypes
        }
        if ($IncludeExclusions) { $Finding.IsExcluded = if ($IsExcluded) {"Y"} else {$null} }
        [PSCustomObject]$Finding
    }

}

$Results = @($Results | Sort-Object DisplayName)

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject $Results

Write-Host "$($Groups.Count) group(s) in raw snapshot."
Write-Host "$($Flagged.Count) group(s) matched the temp/test naming pattern."
Write-Host "$ExcludedCount group(s) excluded via $(Split-Path $ExclusionsPath -Leaf)."
Write-Host "$($Results.Count) finding(s) written to $OutputPath"
