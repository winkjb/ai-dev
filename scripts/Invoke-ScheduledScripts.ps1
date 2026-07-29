<#
.SYNOPSIS
    Central dispatcher for running scripts on Daily / Weekly / Monthly / Quarterly cadences
    from a single Task Scheduler trigger.

.DESCRIPTION
    Reads a manifest (ScriptManifest.csv) describing each script and its cadence.
    Reads a state file (ScriptRunState.json) tracking the last successful run of each script.
    Determines which scripts are due today, AND which ones are overdue/missed
    (e.g. box was off, previous run failed) and catches them up.
    Logs every run, success, failure, and skip to a rolling log file.

.NOTES
    Schedule THIS script once in Task Scheduler (e.g. daily at 6:00 AM).
    It decides internally what actually needs to run.

.PARAMETER DryRun
    If specified, evaluates what WOULD run and logs it, but does not execute anything
    or update the state file. Consistent with the -DryRun pattern used in combine_assessments.py.

.PARAMETER ManifestPath
    Path to the JSON manifest of scripts. Defaults to .\ScriptManifest.json (same folder as this script).

.PARAMETER StatePath
    Path to the JSON file tracking last-run timestamps. Defaults to .\ScriptRunState.json.

.PARAMETER Force
    Runs every enabled script regardless of schedule/state. Useful for manual re-runs or testing.
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$ManifestPath = (Join-Path $PSScriptRoot "..\data\reference\ScriptManifest.csv"),
    [string]$StatePath    = (Join-Path $PSScriptRoot "..\data\reference\ScriptRunState.json"),
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$LogDir  = Join-Path $PSScriptRoot "logs"
$LogFile = Join-Path $LogDir ("Dispatcher_{0:yyyy-MM}.log" -f (Get-Date))

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","SUCCESS","SKIP")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    switch ($Level) {
        "ERROR"   { Write-Host $line -ForegroundColor Red }
        "WARN"    { Write-Host $line -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $line -ForegroundColor Green }
        "SKIP"    { Write-Host $line -ForegroundColor DarkGray }
        default   { Write-Host $line }
    }
}

function ConvertTo-Bool {
    <#
        CSV values come in as plain strings ("TRUE","FALSE","1","yes", or even blank).
        This normalizes any of those into a real boolean.
    #>
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return $Value.Trim() -match '^(true|1|yes)$'
}

function Get-State {
    param([string]$Path)
    if (Test-Path $Path) {
        try {
            $raw = Get-Content -Path $Path -Raw | ConvertFrom-Json
            # Convert to hashtable for easy mutation
            $ht = @{}
            foreach ($prop in $raw.PSObject.Properties) {
                $ht[$prop.Name] = $prop.Value
            }
            return $ht
        } catch {
            Write-Log "State file at $Path is corrupt or unreadable. Starting fresh. Error: $_" -Level WARN
            return @{}
        }
    }
    return @{}
}

function Save-State {
    param([hashtable]$State, [string]$Path)
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding UTF8
}

function Test-IsDue {
    <#
        Returns $true if the script is due to run *today* based purely on its cadence
        (ignores last-run state — that's handled separately for catch-up).
    #>
    param($ScriptDef, [datetime]$Today)

    switch ($ScriptDef.Frequency) {
        "Daily" { return $true }

        "Weekly" {
            $targetDay = $ScriptDef.DayOfWeek
            if (-not $targetDay) { $targetDay = "Monday" }
            return ($Today.DayOfWeek.ToString() -eq $targetDay)
        }

        "Monthly" {
            $targetDom = if ($ScriptDef.DayOfMonth) { [int]$ScriptDef.DayOfMonth } else { 1 }
            return ($Today.Day -eq $targetDom)
        }

        "Quarterly" {
            $targetDom = if ($ScriptDef.DayOfMonth) { [int]$ScriptDef.DayOfMonth } else { 1 }
            $quarterMonths = @(1,4,7,10)
            return (($Today.Month -in $quarterMonths) -and ($Today.Day -eq $targetDom))
        }

        default {
            Write-Log "Unknown frequency '$($ScriptDef.Frequency)' for $($ScriptDef.Name). Skipping." -Level WARN
            return $false
        }
    }
}

function Test-IsOverdue {
    <#
        Compares last successful run against how long ago the cadence *should* have fired.
        Catches cases where the dispatcher itself didn't run (box off, etc.) on the due day.
    #>
    param($ScriptDef, [datetime]$Today, $LastRun)

    if (-not $LastRun) { return $true }  # never run before -> overdue

    $lastRunDate = [datetime]$LastRun
    $daysSince = ($Today.Date - $lastRunDate.Date).Days

    switch ($ScriptDef.Frequency) {
        "Daily"     { return $daysSince -ge 2 }      # missed at least one full day
        "Weekly"    { return $daysSince -ge 8 }       # missed the weekly window
        "Monthly"   { return $daysSince -ge 32 }      # missed the monthly window
        "Quarterly" { return $daysSince -ge 95 }      # missed the quarterly window
        default     { return $false }
    }
}

function Invoke-ScriptDef {
    param($ScriptDef)

    if (-not (Test-Path $ScriptDef.Path)) {
        Write-Log "$($ScriptDef.Name): script not found at $($ScriptDef.Path)" -Level ERROR
        return $false
    }

    try {
        if (ConvertTo-Bool $ScriptDef.IsPython) {
            $argList = @($ScriptDef.Path)
            if ($ScriptDef.Arguments) { $argList += $ScriptDef.Arguments -split ' ' }
            & python $argList
        } else {
            $argList = @()
            if ($ScriptDef.Arguments) { $argList = $ScriptDef.Arguments -split ' ' }
            & $ScriptDef.Path @argList
        }

        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            Write-Log "$($ScriptDef.Name): exited with code $LASTEXITCODE" -Level ERROR
            return $false
        }

        return $true
    } catch {
        Write-Log "$($ScriptDef.Name): threw an exception - $_" -Level ERROR
        return $false
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Log "===== Dispatcher run started $(if ($DryRun) {'(DRY RUN)'}) ====="

if (-not (Test-Path $ManifestPath)) {
    Write-Log "Manifest not found at $ManifestPath. Aborting." -Level ERROR
    exit 1
}

$manifest = Import-Csv -Path $ManifestPath
$state    = Get-State -Path $StatePath
$today    = Get-Date

$results = @()

foreach ($scriptDef in $manifest) {

    if (-not (ConvertTo-Bool $scriptDef.Enabled)) {
        Write-Log "$($scriptDef.Name): disabled in manifest. Skipping." -Level SKIP
        continue
    }

    $lastRun    = $state[$scriptDef.Name]
    $dueToday   = Test-IsDue -ScriptDef $scriptDef -Today $today
    $overdue    = Test-IsOverdue -ScriptDef $scriptDef -Today $today -LastRun $lastRun
    $shouldRun  = $Force -or $dueToday -or $overdue

    if (-not $shouldRun) {
        Write-Log "$($scriptDef.Name): not due. Last run: $(if ($lastRun) {$lastRun} else {'never'})" -Level SKIP
        continue
    }

    $reason = if ($Force) { "forced" } elseif ($dueToday) { "scheduled today" } else { "catch-up (overdue)" }
    Write-Log "$($scriptDef.Name): running - $reason."

    if ($DryRun) {
        Write-Log "$($scriptDef.Name): DRY RUN - would execute $($scriptDef.Path)" -Level SKIP
        $results += [PSCustomObject]@{ Name = $scriptDef.Name; Status = "DryRun" }
        continue
    }

    $success = Invoke-ScriptDef -ScriptDef $scriptDef

    if ($success) {
        $state[$scriptDef.Name] = $today.ToString("o")
        Write-Log "$($scriptDef.Name): completed successfully." -Level SUCCESS
        $results += [PSCustomObject]@{ Name = $scriptDef.Name; Status = "Success" }
    } else {
        Write-Log "$($scriptDef.Name): failed. Last-run state NOT updated - will retry/catch-up next run." -Level ERROR
        $results += [PSCustomObject]@{ Name = $scriptDef.Name; Status = "Failed" }
    }
}

if (-not $DryRun) {
    Save-State -State $state -Path $StatePath
}

Write-Log "===== Dispatcher run finished ====="
Write-Host ""
$results | Format-Table -AutoSize
