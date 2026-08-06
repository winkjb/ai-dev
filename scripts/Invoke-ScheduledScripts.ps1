<#
.SYNOPSIS
    Central dispatcher for running scripts on Daily / Weekly / Monthly / Quarterly cadences

.DESCRIPTION
    Reads a manifest CSV describing each script and its cadence. Reads a state file tracking 
    the last successful run of each script. Determines which scripts are due today, and which 
    ones are overdue/missed and catches them up. Logs every run, success, failure, and skip to 
    a rolling log file.

.PARAMETER DryRun
    If specified, evaluates what WOULD run and logs it, but does not execute anything
    or update the state file. 

.PARAMETER ManifestPath
    Path to the JSON manifest of scripts. Defaults to ..\data\input\ScriptManifest.csv.

.PARAMETER StatePath
    Path to the JSON file tracking last-run timestamps. Defaults to ..\data\input\ScriptRunState.json.

.PARAMETER Force
    Runs every enabled script regardless of schedule/state. Useful for manual re-runs or testing.

.PARAMETER SkipTimingGuard
    Bypasses the run-timing window guard - independent of -Force, since forcing every script to 
    run and ignoring a suspicious trigger time are different concerns. Useful for manual 
    re-runs/testing at any time of day.

.PARAMETER ExpectedHour
    Hour (24h) this dispatcher is expected to be triggered at. Defaults to 7 (matches the
    "e.g. daily at 7:00 AM" Task Scheduler trigger).

.PARAMETER ExpectedMinute
    Minute this dispatcher is expected to be triggered at. Defaults to 0.

.PARAMETER MaxTimingDifferenceMinutes
    How many minutes before/after the expected time still count as a legitimate trigger.
    Defaults to 15.

.PARAMETER DelaySeconds
    Pause between actually-executed scripts (not before the first one, and never a trailing
    wait after the last), to avoid back-to-back API/SMTP hits or piling straight into a
    transient issue right after a prior script failed. Defaults to 30. Set to 0 to disable.
    Doesn't apply to skipped/disabled entries or -DryRun (nothing real happens either way).

.NOTES
    Schedule this script once in Task Scheduler (e.g. daily at 7:00 AM). 
    It decides internally what actually needs to run.

    Run-timing window guard: on multiple customer servers in a previous architecture, a
    Task Scheduler trigger ended up firing outside its expected window in ways that caused
    duplicate/repeated runs - especially around DST changes. Since this dispatcher is meant
    to fire once a day at a known time, a trigger landing well outside that window is treated
    as suspect and the whole run is skipped (not just one script) rather than trusting it.
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$ManifestPath,
    [string]$StatePath,
    [switch]$Force,
    [switch]$SkipTimingGuard,
    [int]$ExpectedHour = 7,
    [int]$ExpectedMinute = 0,
    [int]$MaxTimingDifferenceMinutes = 15,
    [int]$DelaySeconds = 30
)

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# System settings and variables

$ErrorActionPreference = "Stop"
$LogDir  = Join-Path $PSScriptRoot "..\data\output"
$LogFile = Join-Path $LogDir ("dispatcher_{0:yyyy-MM}.log" -f (Get-Date))

# Derived settings and variables

if (-not $ManifestPath) { $ManifestPath = Join-Path $PSScriptRoot "..\data\input\ScriptManifest.csv" }
if (-not $StatePath)    { $StatePath    = Join-Path $PSScriptRoot "..\data\input\ScriptRunState.json" }

# Import functions

. (Join-Path $PSScriptRoot "Functions-VA-Common.ps1")

# Additional functions

function ConvertTo-Bool {
    <#
        CSV values come in as plain strings ("TRUE","FALSE","1","yes", or even blank).
        This normalizes any of those into a real boolean.
    #>
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return $Value.Trim() -match '^(true|1|yes)$'
}

function Get-ScriptStateKey {
    <#
        Unique identity for run-state tracking: Customer + Path. Path alone already differs
        across teams/folders (e.g. project-management vs service-delivery both having their
        own Invoke-CoordinatorReports.ps1); Customer differs across tenants reusing the same
        boilerplate script path. Name/Purpose are cosmetic only and deliberately excluded
        from this key so they never need to be hand-crafted unique.
    #>
    param($ScriptDef)
    return "$($ScriptDef.Customer)::$($ScriptDef.Path)"
}

function Get-ScriptDisplayLabel {
    <#
        Human-readable label for log lines - joins whichever of Purpose/Customer/Name are
        populated (most rows today have no Customer, since they're internal, not per-tenant).
    #>
    param($ScriptDef)
    $Parts = @($ScriptDef.Purpose, $ScriptDef.Customer, $ScriptDef.Name) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    return ($Parts -join " / ")
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
            Write-Log "Unknown frequency '$($ScriptDef.Frequency)' for $(Get-ScriptDisplayLabel -ScriptDef $ScriptDef). Skipping." -Level WARN
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

function Resolve-ScriptDefPath {
    <#
        Manifest Path values can be absolute (for scripts genuinely outside the repo, like
        the Proofpoint/Quarterly-ClientReview legacy entries under C:\Scripts\...) or
        relative to the repo root (e.g. project-management\01-coordinator\Invoke-
        CoordinatorReports.ps1) - relative paths keep the manifest portable if this
        workspace ever gets cloned/moved somewhere other than its current location, per
        CLAUDE.md's relative-paths convention. $PSScriptRoot here is always this dispatcher's
        own scripts\ folder, so its parent is a stable repo-root anchor regardless of how
        or from where the dispatcher gets invoked.
    #>
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    $RepoRoot = Split-Path $PSScriptRoot -Parent
    return Join-Path $RepoRoot $Path
}

function ConvertTo-ArgumentHashtable {
    <#
        Converts a simple "-Name value -Switch -Other value" Arguments string into a
        hashtable for splatting (@hashtable) into a PowerShell script's own named/switch
        parameters. Deliberately NOT a plain array splat (@array) - confirmed live that
        array splatting only binds POSITIONALLY, so a leading "-DryRun" silently landed on
        Remove-OldLogs.ps1's first positional parameter ($RetentionMonths, an int) and threw
        a type-conversion error instead of being recognized as the switch it looks like.
        Only affects the PowerShell-script branch below - the python branch passes argv
        straight through to a native exe, where dash-prefixed tokens were never a binding
        problem in the first place (python's own argparse handles them, not PowerShell).
    #>
    param([string]$ArgumentString)

    $Result = @{}
    if ([string]::IsNullOrWhiteSpace($ArgumentString)) { return $Result }

    $Tokens = @($ArgumentString -split '\s+' | Where-Object { $_ })
    $i = 0
    while ($i -lt $Tokens.Count) {
        $Token = $Tokens[$i]
        if ($Token -notlike '-*') {
            throw "Unexpected positional argument '$Token' in Arguments string '$ArgumentString' - only named/switch parameters (-Name value / -Switch) are supported."
        }
        $Name = $Token.TrimStart('-')
        $NextIsValue = ($i + 1 -lt $Tokens.Count) -and ($Tokens[$i + 1] -notlike '-*')
        if ($NextIsValue) {
            $Result[$Name] = $Tokens[$i + 1]
            $i += 2
        } else {
            $Result[$Name] = $true
            $i += 1
        }
    }
    return $Result
}

function Invoke-ScriptDef {
    param($ScriptDef)

    $ResolvedPath = Resolve-ScriptDefPath -Path $ScriptDef.Path

    if (-not (Test-Path $ResolvedPath)) {
        Write-Log "$(Get-ScriptDisplayLabel -ScriptDef $ScriptDef): script not found at $ResolvedPath" -Level ERROR
        return $false
    }

    try {
        if (ConvertTo-Bool $ScriptDef.IsPython) {
            $argList = @($ResolvedPath)
            if ($ScriptDef.Arguments) { $argList += $ScriptDef.Arguments -split ' ' }
            & python $argList
        } else {
            $ArgHash = ConvertTo-ArgumentHashtable -ArgumentString $ScriptDef.Arguments
            & $ResolvedPath @ArgHash
        }

        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            Write-Log "$(Get-ScriptDisplayLabel -ScriptDef $ScriptDef): exited with code $LASTEXITCODE" -Level ERROR
            return $false
        }

        return $true
    } catch {
        Write-Log "$(Get-ScriptDisplayLabel -ScriptDef $ScriptDef): threw an exception - $_" -Level ERROR
        return $false
    }
}

# Validate logfile directory

Test-Directory $LogDir

# Validate run time

if (-not $SkipTimingGuard) {
    $Now = Get-Date
    $ExpectedTime = Get-Date -Hour $ExpectedHour -Minute $ExpectedMinute -Second 0
    $TimingDifference = [math]::Abs((New-TimeSpan -Start $ExpectedTime -End $Now).TotalMinutes)

    if ($TimingDifference -gt $MaxTimingDifferenceMinutes) {
        Write-Log "Skipping run - triggered outside expected window. Now: $Now. Expected: $ExpectedTime (+/-$MaxTimingDifferenceMinutes min). Difference: $([math]::Round($TimingDifference, 1)) min." -Level WARN
        exit 0
    }
}

# ---------------------------------------------------------------------------
# Run scripts
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
$HasRunAny = $false

foreach ($scriptDef in $manifest) {

    $Label    = Get-ScriptDisplayLabel -ScriptDef $scriptDef
    $StateKey = Get-ScriptStateKey -ScriptDef $scriptDef

    if (-not (ConvertTo-Bool $scriptDef.Enabled)) {
        Write-Log "$Label`: disabled in manifest. Skipping." -Level SKIP
        continue
    }

    $lastRun    = $state[$StateKey]
    $dueToday   = Test-IsDue -ScriptDef $scriptDef -Today $today
    $overdue    = Test-IsOverdue -ScriptDef $scriptDef -Today $today -LastRun $lastRun
    $shouldRun  = $Force -or $dueToday -or $overdue

    if (-not $shouldRun) {
        Write-Log "$Label`: not due. Last run: $(if ($lastRun) {$lastRun} else {'never'})" -Level SKIP
        continue
    }

    $reason = if ($Force) { "forced" } elseif ($dueToday) { "scheduled today" } else { "catch-up (overdue)" }
    Write-Log "$Label`: running - $reason."

    if ($DryRun) {
        Write-Log "$Label`: DRY RUN - would execute $($scriptDef.Path)" -Level SKIP
        $results += [PSCustomObject]@{ Name = $scriptDef.Name; Customer = $scriptDef.Customer; Purpose = $scriptDef.Purpose; Status = "DryRun" }
        continue
    }

    if ($HasRunAny -and $DelaySeconds -gt 0) {
        Write-Log "Waiting $DelaySeconds second(s) before $Label..."
        Start-Sleep -Seconds $DelaySeconds
    }

    $success = Invoke-ScriptDef -ScriptDef $scriptDef
    $HasRunAny = $true

    if ($success) {
        $state[$StateKey] = $today.ToString("o")
        Write-Log "$Label`: completed successfully." -Level SUCCESS
        $results += [PSCustomObject]@{ Name = $scriptDef.Name; Customer = $scriptDef.Customer; Purpose = $scriptDef.Purpose; Status = "Success" }
    } else {
        Write-Log "$Label`: failed. Last-run state NOT updated - will retry/catch-up next run." -Level ERROR
        $results += [PSCustomObject]@{ Name = $scriptDef.Name; Customer = $scriptDef.Customer; Purpose = $scriptDef.Purpose; Status = "Failed" }
    }

}

# Update run states

if (-not $DryRun) {
    Save-State -State $state -Path $StatePath
}

Write-Log "===== Dispatcher run finished ====="
Write-Host ""
$results | Format-Table -AutoSize
