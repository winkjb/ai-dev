<#
    Local staleness history for the Flags report only (Get-CoordinatorProjectData.ps1 and the
    other two coordinator reports don't need this). Tracks, per Autotask project ID, the last
    known value and last-changed date for the % Complete signals that Autotask itself
    doesn't store anywhere (unlike Status, which has its own native statusDateTime field - see
    Get-CoordinatorProjectData.ps1's docstring), plus Actual Hours - tracked the same way even
    though Autotask does store the raw number, because % Complete - Hours can sit stuck at 0%
    (no estimated hours entered) while real time keeps getting logged against the project.

    A signal's LastChanged starts - and stays - $null ("unknown") until a real value change is
    actually observed; it is never seeded with today's date on first sight of a project. See
    Get-DaysSinceSignalChange for how that's used once flagging staleness.
#>

function Get-ProjectSnapshotHistory {

    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return @{} }

    $Raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($Raw)) { return @{} }

    $Parsed = $Raw | ConvertFrom-Json
    $History = @{}
    foreach ($prop in $Parsed.PSObject.Properties) {
        $History[$prop.Name] = @{
            Hours = @{
                Value       = $prop.Value.Hours.Value
                LastChanged = $prop.Value.Hours.LastChanged
                FirstSeen   = $prop.Value.Hours.FirstSeen
            }
            Task  = @{
                Value       = $prop.Value.Task.Value
                LastChanged = $prop.Value.Task.LastChanged
                FirstSeen   = $prop.Value.Task.FirstSeen
            }
            ActualHours = @{
                Value       = $prop.Value.ActualHours.Value
                LastChanged = $prop.Value.ActualHours.LastChanged
                FirstSeen   = $prop.Value.ActualHours.FirstSeen
            }
        }
    }
    return $History
}

function Update-ProjectSnapshotHistory {

    # Mutates $History in place (project ID -> @{ Hours = @{Value;LastChanged;FirstSeen}; Task = @{...} }),
    # comparing today's % Complete - Hours / % Complete - Task against the stored value at the same
    # 2-decimal rounding already used for display, so formatting noise never fakes a "change". Any
    # project ID not present in $Projects (closed/no longer in scope) is pruned. Writes atomically
    # (temp file + Move-Item) so a crash mid-write can't corrupt the history.

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$History,
        [Parameter(Mandatory)] [array]$Projects,
        [Parameter(Mandatory)] [string]$Path,
        [datetime]$Today = (Get-Date)
    )

    $TodayStr = $Today.ToString("yyyy-MM-dd")
    $SeenIds = @{}

    foreach ($p in $Projects) {
        $Id = [string]$p.'Project ID'
        $SeenIds[$Id] = $true

        $HoursValue = [math]::Round([double]($p.'% Complete - Hours' -replace '[%,]', ''), 2)
        $TaskValue  = [math]::Round([double]($p.'% Complete - Task' -replace '[%,]', ''), 2)
        $ActualHoursValue = [math]::Round([double]($p.'Actual Hours' -replace ',', ''), 2)

        if (-not $History.ContainsKey($Id)) {
            $History[$Id] = @{
                Hours = @{ Value = $HoursValue; LastChanged = $null; FirstSeen = $TodayStr }
                Task  = @{ Value = $TaskValue;  LastChanged = $null; FirstSeen = $TodayStr }
                ActualHours = @{ Value = $ActualHoursValue; LastChanged = $null; FirstSeen = $TodayStr }
            }
            continue
        }

        $Entry = $History[$Id]
        foreach ($Signal in @(
            @{ Name = "Hours"; Value = $HoursValue }
            @{ Name = "Task";  Value = $TaskValue }
            @{ Name = "ActualHours"; Value = $ActualHoursValue }
        )) {
            if (-not $Entry.ContainsKey($Signal.Name) -or $null -eq $Entry[$Signal.Name] -or $null -eq $Entry[$Signal.Name].Value) {
                $Entry[$Signal.Name] = @{ Value = $Signal.Value; LastChanged = $null; FirstSeen = $TodayStr }
                continue
            }
            $Sub = $Entry[$Signal.Name]
            if ($Sub.Value -ne $Signal.Value) { $Sub.LastChanged = $TodayStr }
            $Sub.Value = $Signal.Value
        }
    }

    foreach ($Id in @($History.Keys | Where-Object { -not $SeenIds.ContainsKey($_) })) {
        $History.Remove($Id)
    }

    $OutputDir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

    $Ordered = [ordered]@{}
    foreach ($Id in ($History.Keys | Sort-Object)) { $Ordered[$Id] = $History[$Id] }

    $Json = $Ordered | ConvertTo-Json -Depth 10
    $TempPath = "$Path.tmp"
    [System.IO.File]::WriteAllText($TempPath, $Json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $TempPath -Destination $Path -Force
}

function Get-DaysSinceSignalChange {

    # Days since $Signal.LastChanged if we've ever observed a real change, else days since
    # $Signal.FirstSeen (the fallback that lets genuine staleness surface once enough observation
    # history has accumulated, without ever fabricating a "changed today" date). $null if $Signal
    # itself is missing entirely.

    [CmdletBinding()]
    param(
        $Signal,
        [datetime]$Reference = (Get-Date)
    )

    if ($null -eq $Signal) { return $null }

    $DateStr = if ($Signal.LastChanged) { $Signal.LastChanged } else { $Signal.FirstSeen }
    if (-not $DateStr) { return $null }

    $Parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse($DateStr, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$Parsed)) {
        return $null
    }

    return [math]::Floor(($Reference - $Parsed).TotalDays)
}
