<#
.SYNOPSIS
    Collector-only: pulls Entra sign-in log events over a lookback window via Graph API - raw
    and unfiltered, no interpretation, no Analyst layer. Writes one raw log export to
    data/raw/<Directory>/EntraUserSignIns.csv, which the customer wrapper emails directly (see
    ../katz/Invoke-LogAudit-UserSignIns.ps1) since there's currently nothing to compare it
    against.

.DESCRIPTION
    This is a raw log export, not a compare-to-baseline audit - unlike every other Collector in
    this workspace, there's no paired Analyst script (see
    ../01-collector/Collect-EntraUserActivities.ps1's .DESCRIPTION for the same note and Brad's
    noted future direction: an Analyst that flags sign-ins that would've been blocked if not
    for a Conditional Access policy, or a failed-vs-successful rollup).

    Pulled in daily slices via Invoke-GraphRequest (retries 429/503/504 with backoff,
    Functions-M365-Common.ps1). Each event is flattened to one row via Write-IncrementalCsv -
    written as it's fetched rather than held in memory, since a busy tenant's full sign-in log
    can be large. If nothing at all was found in the window, a single placeholder row is
    written so the CSV isn't empty and downstream size/attach logic (in the orchestrator) has
    something to check.

    -ReportOnly narrows each event's AppliedConditionalAccessPolicies down to only policies that
    ran in report-only mode (reportOnlySuccess/reportOnlyFailure/reportOnlyNotApplied) - events
    with no such policy applied are skipped entirely when this is set. This is a genuine
    collection-time scoping choice (which Graph data to keep), not interpretation of what it
    means, so it stays at this layer rather than moving to an Analyst.

    -LookBackDays/-Top default to 30/200, matching the real production wrapper's actual values.

.EXAMPLE
    .\Collect-EntraUserSignIns.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [int]$LookBackDays = 30,
    [int]$Top = 200,
    [switch]$ReportOnly,

    [string]$SettingsPath,
    [string]$OutputPath
)

if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot "..\data\reference\$Directory\M365Settings.txt" }
if (-not $OutputPath)   { $OutputPath   = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraUserSignIns.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-M365-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$StartTime = Get-Date
$Script:CountFetched = 0
$Script:CountWritten = 0

$CustomerSettings = Import-Settings -SettingsPath $SettingsPath

Test-Directory (Split-Path $OutputPath -Parent)
if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }

function Get-SignInsUri {
    param([datetime]$StartUtc, [datetime]$EndUtc, [int]$Top)
    $Start = $StartUtc.ToString("s") + "Z"
    $End   = $EndUtc.ToString("s") + "Z"
    "https://graph.microsoft.com/beta/auditLogs/signIns?`$filter=createdDateTime ge $Start and createdDateTime lt $End&`$orderby=createdDateTime desc&`$top=$Top"
}

function Convert-ObjectPropertiesToString {
    param($InputObject)
    if (-not $InputObject) { return "" }
    ($InputObject.PSObject.Properties | ForEach-Object { "$($_.Name): $($_.Value)" }) -join "; "
}

function Convert-PolicyDetailsToString {
    param($Policies)
    if (-not $Policies) { return "" }
    ($Policies | ForEach-Object {
        "ID: $($_.id); DisplayName: $($_.displayName); Result: $($_.result); " +
        "ConditionsNotSatisfied: $($_.conditionsNotSatisfied -join ', '); " +
        "SessionControlsNotSatisfied: $($_.sessionControlsNotSatisfied -join ', ')"
    }) -join "`n"
}

function Convert-NetworkLocationDetailsToString {
    param($NetworkLocationDetails)
    if (-not $NetworkLocationDetails) { return "" }
    ($NetworkLocationDetails | ForEach-Object {
        ($_.PSObject.Properties | ForEach-Object { "$($_.Name): $($_.Value)" }) -join "; "
    }) -join "`n"
}

function Convert-AuthenticationDetailsToString {
    param($AuthenticationDetails)
    if (-not $AuthenticationDetails) { return "" }
    ($AuthenticationDetails | ForEach-Object {
        "AuthenticationStepDateTime: $($_.authenticationStepDateTime); " +
        "AuthenticationMethod: $($_.authenticationMethod); " +
        "AuthenticationMethodDetail: $($_.authenticationMethodDetail); " +
        "Succeeded: $($_.succeeded); " +
        "AuthenticationStepResultDetail: $($_.authenticationStepResultDetail); " +
        "AuthenticationStepRequirement: $($_.authenticationStepRequirement);"
    }) -join "`n"
}

function Get-MatchingPolicies {
    param($Event, [bool]$ReportOnly)
    if (-not $Event.appliedConditionalAccessPolicies) { return @() }
    if ($ReportOnly) {
        $ResultsToMatch = @('reportOnlySuccess', 'reportOnlyFailure', 'reportOnlyNotApplied')
        return @($Event.appliedConditionalAccessPolicies | Where-Object { $_.result -in $ResultsToMatch })
    }
    return @($Event.appliedConditionalAccessPolicies)
}

function Write-SignInRecords {
    param([array]$Events, [string]$OutputPath, [bool]$ReportOnly)

    foreach ($Event in $Events) {

        $Script:EventIndex++
        if (($Script:EventIndex % 250) -eq 0) { Write-Progress -Activity "Processing..." -Status "$($Script:EventIndex) events completed" }

        $MatchingPolicies = Get-MatchingPolicies -Event $Event -ReportOnly $ReportOnly
        if ($ReportOnly -and @($MatchingPolicies).Count -eq 0) { continue }

        $Record = [ordered]@{
            CreatedDateTime                  = $Event.createdDateTime
            UserDisplayName                  = $Event.userDisplayName
            UserPrincipalName                = $Event.userPrincipalName
            AppId                            = $Event.appId
            AppDisplayName                   = $Event.appDisplayName
            IpAddress                        = $Event.ipAddress
            ClientApp                        = $Event.clientAppUsed
            UserAgent                        = $Event.userAgent
            CorrelationId                    = $Event.correlationId
            IsInteractive                    = $Event.isInteractive
            AuthenticationRequirement        = $Event.authenticationRequirement
            EventStatus                      = Convert-ObjectPropertiesToString -InputObject $Event.status
            DeviceDetail                     = Convert-ObjectPropertiesToString -InputObject $Event.deviceDetail
            Location                         = Convert-ObjectPropertiesToString -InputObject $Event.location
            ConditionalAccessStatus          = $Event.conditionalAccessStatus
            AppliedConditionalAccessPolicies = Convert-PolicyDetailsToString -Policies $MatchingPolicies
            NetworkLocationDetails           = Convert-NetworkLocationDetailsToString -NetworkLocationDetails $Event.networkLocationDetails
            AuthenticationDetails            = Convert-AuthenticationDetailsToString -AuthenticationDetails $Event.authenticationDetails
        }

        Write-IncrementalCsv -Path $OutputPath -InputObject ([PSCustomObject]$Record)
        $Script:CountWritten++

    }

}

function Get-SignIns {
    param([datetime]$StartUtc, [datetime]$EndUtc, [int]$Top, $CustomerSettings, [string]$OutputPath, [bool]$ReportOnly)

    $Uri = Get-SignInsUri -StartUtc $StartUtc -EndUtc $EndUtc -Top $Top

    do {
        $Headers = @{ Authorization = "Bearer $(Get-GraphToken -CustomerSettings $CustomerSettings)" }
        $Response = Invoke-GraphRequest -Url $Uri -Headers $Headers

        $Events = @($Response.value)
        if ($Events.Count -gt 0) {
            $Script:CountFetched += $Events.Count
            Write-SignInRecords -Events $Events -OutputPath $OutputPath -ReportOnly $ReportOnly
        }

        $Uri = $Response.'@odata.nextLink'
    } while ($Uri)

}

# --- pull, one day at a time ---------------------------------------------------------------

$Script:EventIndex = 0
$EndUtc = (Get-Date).ToUniversalTime()
$StartUtc = $EndUtc.AddDays(-$LookBackDays)
$Cursor = $EndUtc

while ($Cursor -gt $StartUtc) {

    $SliceStart = $Cursor.AddDays(-1)
    if ($SliceStart -lt $StartUtc) { $SliceStart = $StartUtc }

    try {
        Get-SignIns -StartUtc $SliceStart -EndUtc $Cursor -Top $Top -CustomerSettings $CustomerSettings -OutputPath $OutputPath -ReportOnly $ReportOnly.IsPresent
        Write-Host ("{0} -> {1} processed" -f $SliceStart.ToString("s"), $Cursor.ToString("s")) -ForegroundColor Cyan
    } catch {
        Write-Host ("Slice {0} -> {1} failed: {2}" -f $SliceStart.ToString("s"), $Cursor.ToString("s"), $_.Exception.Message) -ForegroundColor Yellow
    }

    $Cursor = $SliceStart

}

# --- placeholder row if nothing at all was written ---------------------------------------------------------------

if ($Script:CountWritten -eq 0) {
    $NoDataRecord = [ordered]@{
        CreatedDateTime = $null; UserDisplayName = $null; UserPrincipalName = $null; AppId = $null; AppDisplayName = $null
        IpAddress = $null; ClientApp = $null; UserAgent = $null; CorrelationId = $null; IsInteractive = $null
        AuthenticationRequirement = $null
        EventStatus = "No sign-in events between $($StartUtc.ToString('s')) and $($EndUtc.ToString('s')) (UTC)"
        DeviceDetail = $null; Location = $null; ConditionalAccessStatus = $null
        AppliedConditionalAccessPolicies = $null; NetworkLocationDetails = $null; AuthenticationDetails = $null
    }
    Write-IncrementalCsv -Path $OutputPath -InputObject ([PSCustomObject]$NoDataRecord)
}

$TotalSeconds = ((Get-Date) - $StartTime).TotalSeconds
Write-Host ("Fetched {0} event(s), wrote {1} record(s) to {2} in {3:N0}s" -f $Script:CountFetched, $Script:CountWritten, $OutputPath, $TotalSeconds) -ForegroundColor Green
