<#
.SYNOPSIS
    Collector-only: pulls Entra directory audit log events over a lookback window via Graph
    API - raw and unfiltered, no interpretation, no Analyst layer. Writes one raw log export to
    data/raw/<Directory>/EntraUserActivities.csv, which the customer wrapper emails directly
    (see ../katz/Invoke-LogAudit-UserActivities.ps1) since there's currently nothing to compare
    it against.

.DESCRIPTION
    This is a raw log export, not a compare-to-baseline audit - unlike every other Collector in
    this workspace, there's no paired Analyst script. The original script had none either (no
    filtering, no flagging - every event in the window gets written). Brad's noted a real future
    direction here once this is worth a second look: an Analyst layer that flags sign-ins/actions
    that would have been blocked if not for a Conditional Access policy, or a rollup of
    failed-vs-successful logon attempts to gauge how hard an org is being targeted. Not built
    yet - this collector is deliberately just the raw pull for now.

    Pulled in daily slices (Graph's directoryAudits endpoint has result-window limits that a
    single wide date-range query can hit on an active tenant) via Invoke-GraphRequest, which
    already retries 429/503/504 with backoff (Functions-M365-Common.ps1). Each event is
    flattened to one row per modified property (or one row per target resource, if it changed
    nothing) via Write-IncrementalCsv - written as it's fetched rather than held in memory, since
    a busy tenant's full audit log can be large. If nothing at all was found in the window, a
    single placeholder row is written so the CSV isn't empty and downstream size/attach logic
    (in the orchestrator) has something to check.

    -LookBackDays/-Top default to 30/200, matching the real production wrapper's actual values.

.EXAMPLE
    .\Collect-EntraUserActivities.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [int]$LookBackDays = 30,
    [int]$Top = 200,

    [string]$SettingsPath,
    [string]$OutputPath
)

if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot "..\data\reference\$Directory\M365Settings.txt" }
if (-not $OutputPath)   { $OutputPath   = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraUserActivities.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-M365-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$StartTime = Get-Date
$Script:CountEvents = 0
$Script:CountRecords = 0

$CustomerSettings = Import-Settings -SettingsPath $SettingsPath

Test-Directory (Split-Path $OutputPath -Parent)
if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }

function Get-DirectoryAuditsUri {
    param([datetime]$StartUtc, [datetime]$EndUtc, [int]$Top)
    $Start = $StartUtc.ToString("s") + "Z"
    $End   = $EndUtc.ToString("s") + "Z"
    "https://graph.microsoft.com/beta/auditLogs/directoryAudits?`$filter=activityDateTime ge $Start and activityDateTime lt $End&`$orderby=activityDateTime desc&`$top=$Top"
}

function Write-ActivityRecords {
    param([array]$Events, [string]$OutputPath)

    foreach ($Event in @($Events)) {

        $Script:CountEvents++
        if ($Script:CountEvents % 250 -eq 0) { Write-Progress -Activity "Processing..." -Status "$($Script:CountEvents) events completed" }

        $InitiatedBy =
            if ($Event.initiatedBy.user.displayName) { $Event.initiatedBy.user.displayName }
            elseif ($Event.initiatedBy.app.displayName) { $Event.initiatedBy.app.displayName }
            else { $null }

        $Targets = @($Event.targetResources)
        if ($Targets.Count -eq 0) {
            $Targets = @([PSCustomObject]@{ id = $null; displayName = $null; type = $null; userPrincipalName = $null; modifiedProperties = @() })
        }

        foreach ($Target in $Targets) {

            $ModifiedProperties = @($Target.modifiedProperties)
            $AdditionalDetails = (@($Event.additionalDetails) | ForEach-Object { "$($_.key): $($_.value)" }) -join "; "

            $BaseRecord = [ordered]@{
                ActivityDateTime    = $Event.activityDateTime
                ActivityDisplayName = $Event.activityDisplayName
                EventId             = $Event.id
                InitiatedBy         = $InitiatedBy
                Category            = $Event.category
                CorrelationId       = $Event.correlationId
                LoggedByService     = $Event.loggedByService
                OperationType       = $Event.operationType
                Result              = $Event.result
                TargetId            = $Target.id
                TargetDisplayName   = $Target.displayName
                TargetType          = $Target.type
                TargetUPN           = $Target.userPrincipalName
                ModifiedProperty    = $null
                OldValue            = $null
                NewValue            = $null
                AdditionalDetails   = $AdditionalDetails
                UserAgent           = $Event.userAgent
            }

            if ($ModifiedProperties.Count -gt 0) {
                foreach ($Property in $ModifiedProperties) {
                    $Record = [ordered]@{} + $BaseRecord
                    $Record.ModifiedProperty = $Property.displayName
                    $Record.OldValue = $Property.oldValue
                    $Record.NewValue = $Property.newValue
                    Write-IncrementalCsv -Path $OutputPath -InputObject ([PSCustomObject]$Record)
                    $Script:CountRecords++
                }
            } else {
                Write-IncrementalCsv -Path $OutputPath -InputObject ([PSCustomObject]$BaseRecord)
                $Script:CountRecords++
            }

        }

    }

}

function Get-Activities {
    param([datetime]$StartUtc, [datetime]$EndUtc, [int]$Top, [PSCustomObject]$CustomerSettings, [string]$OutputPath)

    $SliceEventCount = 0
    $Uri = Get-DirectoryAuditsUri -StartUtc $StartUtc -EndUtc $EndUtc -Top $Top

    $Headers = @{ Authorization = "Bearer $(Get-GraphToken -CustomerSettings $CustomerSettings)" }
    $Response = Invoke-GraphRequest -Url $Uri -Headers $Headers

    while ($true) {

        $Events = @($Response.value)
        if ($Events.Count -gt 0) {
            Write-ActivityRecords -Events $Events -OutputPath $OutputPath
            $SliceEventCount += $Events.Count
        }

        if (-not $Response.'@odata.nextLink') { break }

        $Headers = @{ Authorization = "Bearer $(Get-GraphToken -CustomerSettings $CustomerSettings)" }
        $Response = Invoke-GraphRequest -Url $Response.'@odata.nextLink' -Headers $Headers

    }

    return $SliceEventCount
}

# --- pull, one day at a time ---------------------------------------------------------------

$EndUtc = (Get-Date).ToUniversalTime()
$StartUtc = $EndUtc.AddDays(-$LookBackDays)
$Cursor = $EndUtc

while ($Cursor -gt $StartUtc) {

    $SliceStart = $Cursor.AddDays(-1)
    if ($SliceStart -lt $StartUtc) { $SliceStart = $StartUtc }

    try {
        $SliceCount = Get-Activities -StartUtc $SliceStart -EndUtc $Cursor -Top $Top -CustomerSettings $CustomerSettings -OutputPath $OutputPath
        Write-Host ("{0} -> {1}: {2} event(s)" -f $SliceStart.ToString("s"), $Cursor.ToString("s"), $SliceCount) -ForegroundColor Cyan
    } catch {
        Write-Host ("Slice {0} -> {1} failed: {2}" -f $SliceStart.ToString("s"), $Cursor.ToString("s"), $_.Exception.Message) -ForegroundColor Yellow
    }

    $Cursor = $SliceStart

}

# --- placeholder row if nothing at all was found ---------------------------------------------------------------

if ($Script:CountRecords -eq 0) {
    $NoDataRecord = [ordered]@{
        ActivityDateTime = $null; ActivityDisplayName = $null; EventId = $null; InitiatedBy = $null
        Category = $null; CorrelationId = $null; LoggedByService = $null; OperationType = $null; Result = $null
        TargetId = $null; TargetDisplayName = $null; TargetType = $null; TargetUPN = $null
        ModifiedProperty = $null; OldValue = $null; NewValue = $null
        AdditionalDetails = "No user activities between $($StartUtc.ToString('s')) and $($EndUtc.ToString('s')) (UTC)"
        UserAgent = $null
    }
    Write-IncrementalCsv -Path $OutputPath -InputObject ([PSCustomObject]$NoDataRecord)
}

$TotalSeconds = ((Get-Date) - $StartTime).TotalSeconds
Write-Host ("Fetched {0} event(s), wrote {1} record(s) to {2} in {3:N0}s" -f $Script:CountEvents, $Script:CountRecords, $OutputPath, $TotalSeconds) -ForegroundColor Green
