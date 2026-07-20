###################################################################################################################
##
## Shared load/exclude/phase-mapping logic for the three coordinator report scripts, dot source this file to use.
##
###################################################################################################################

$PHASE_ORDER = @("Beginning", "In Process", "Closing", "Final Closure", "On Hold/Inactive")
$UNKNOWN_PHASE_LABEL = "Unknown Phase"
$NO_LEAD_LABEL = "(No Project Lead Listed)"
$NO_TECH_LEAD_LABEL = "(No Tech Lead Listed)"

function Import-CoordinatorProjectData {

    [CmdletBinding()]
    param(
        [string]$RawExportPath,
        [string]$ExcludedListPath,
        [string]$PhaseMappingPath
    )

    if (-not $RawExportPath) { $RawExportPath = Join-Path $PSScriptRoot "..\data\raw\Project Search Results.csv" }
    if (-not $ExcludedListPath) { $ExcludedListPath = Join-Path $PSScriptRoot "..\data\reference\excluded-projects.csv" }
    if (-not $PhaseMappingPath) { $PhaseMappingPath = Join-Path $PSScriptRoot "..\data\reference\status-phase-mapping.csv" }

    [PSCustomObject]@{
        Projects = @(Import-Csv -Path $RawExportPath -Encoding UTF8)
        Excluded = @(Import-Csv -Path $ExcludedListPath -Encoding UTF8)
        PhaseMap = @(Import-Csv -Path $PhaseMappingPath -Encoding UTF8)
    }
}

function Remove-ExcludedProjects {

    # Excludes by Project Number (specific one-off placeholders) or Project Type
    # (e.g. Proposal - also filtered server-side now, this stays as a safety net).

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [array]$Projects,
        [Parameter(Mandatory)] [array]$Excluded
    )

    $ExclNumbers = @($Excluded | Where-Object { $_.'Match Type' -eq 'Project Number' } | ForEach-Object { $_.Value })
    $ExclTypes = @($Excluded | Where-Object { $_.'Match Type' -eq 'Project Type' } | ForEach-Object { $_.Value })

    $Kept = [System.Collections.Generic.List[object]]::new()
    $ExcludedCount = 0
    foreach ($p in $Projects) {
        if ($ExclNumbers -contains $p.'Project Number' -or $ExclTypes -contains $p.'Project Type') {
            $ExcludedCount++
        }
        else {
            $Kept.Add($p)
        }
    }

    [PSCustomObject]@{
        Projects      = $Kept
        ExcludedCount = $ExcludedCount
    }
}

function Set-Utf8NoBomContent {

    # Windows PowerShell 5.1's -Encoding UTF8 always writes a BOM; the original Python
    # reports never had one. Matches Python's write_text - exact content, no BOM, no
    # trailing newline added.

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Value
    )

    [System.IO.File]::WriteAllText($Path, $Value, [System.Text.UTF8Encoding]::new($false))
}

function Export-Utf8NoBomCsv {

    # Same BOM problem as Set-Utf8NoBomContent, for CSV output (the original pandas
    # to_csv() output files - unlike the BOM'd raw Autotask export - never had one).

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [array]$InputObject
    )

    $Csv = $InputObject | ConvertTo-Csv -NoTypeInformation
    Set-Utf8NoBomContent -Path $Path -Value (($Csv -join "`r`n") + "`r`n")
}

function Add-ProjectPhase {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [array]$Projects,
        [Parameter(Mandatory)] [array]$PhaseMap
    )

    $Lookup = @{}
    foreach ($row in $PhaseMap) { $Lookup[$row.Status] = $row.Phase }

    $UnmappedStatuses = @($Projects.Status | Select-Object -Unique | Where-Object { -not $Lookup.ContainsKey($_) })
    if ($UnmappedStatuses.Count -gt 0) {
        Write-Warning "$($UnmappedStatuses.Count) status value(s) not in status-phase-mapping.csv, bucketed as '$UNKNOWN_PHASE_LABEL': $($UnmappedStatuses -join ', ')"
    }

    foreach ($p in $Projects) {
        $Phase = $Lookup[$p.Status]
        if (-not $Phase) { $Phase = $UNKNOWN_PHASE_LABEL }
        $p | Add-Member -NotePropertyName "Phase" -NotePropertyValue $Phase -Force
    }

    return $Projects
}
