<#
.SYNOPSIS
    Analyst (prototype): summarizes a customer's collected sign-in log
    (../01-collector/Collect-EntraUserSignIns.ps1's raw export) into total attempts vs.
    successful/failed counts. Does not call Graph.

.DESCRIPTION
    Mock-up per Brad's ask (2026-08-18) - not yet wired into an orchestrator/wrapper, no
    exclusion-file convention, no email. Point is just to see the shape of the summary before
    deciding whether/how to build it out for real.

    Success/failure is read from the raw EventStatus column, which the Collector already
    flattens from Graph's sign-in `status` object into a string like "errorCode: 0;
    failureReason: ...; additionalDetails: ...". errorCode 0 is Graph's own convention for a
    successful sign-in (confirmed against a real 28MB production export, 2026-08-18) - any other
    numeric code is a specific failure reason (e.g. 50126 = invalid credentials, 50074 = MFA
    required). A row whose EventStatus doesn't contain a parseable errorCode at all is counted
    separately as Unknown rather than silently folded into either bucket - the raw log's
    "no activity in this window" placeholder row (see the Collector) is exactly this case.

    Also breaks totals down by day (CreatedDateTime's date) - not explicitly asked for, but
    cheap given the data's already timestamped, and it's a first step toward Brad's stated
    longer-term interest in seeing failed-attempt *trends*, not just a point-in-time total.

.EXAMPLE
    .\Compare-Users-SignInSummary.ps1 -Directory katz -RawPath "..\data\raw\katz\202607 - EntraLogs.csv"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [string]$RawPath,
    [string]$OutputPath
)

if (-not $RawPath)    { $RawPath    = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraUserSignIns.csv" }
if (-not $OutputPath) { $OutputPath = Join-Path $PSScriptRoot "output\$Directory\Users-SignInSummary.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$Now = Get-Date

# --- load -----------------------------------------------------------------

$Events = @(Import-Csv -LiteralPath $RawPath -Encoding UTF8)

# --- classify each row -------------------------------------------------------------------

$Classified = foreach ($Event in $Events) {

    $Day = $null
    if ($Event.CreatedDateTime) {
        $Parsed = [datetime]::MinValue
        if ([datetime]::TryParse($Event.CreatedDateTime, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$Parsed)) {
            $Day = $Parsed.ToString("yyyy-MM-dd")
        }
    }

    $Outcome =
        if ($Event.EventStatus -match 'errorCode:\s*(\d+)') {
            if ($Matches[1] -eq '0') { "Success" } else { "Failed" }
        } else {
            "Unknown"
        }

    [PSCustomObject]@{ Day = $Day; Outcome = $Outcome }

}

# --- overall summary -------------------------------------------------------------------

$Total = $Classified.Count
$SuccessCount = @($Classified.Where({ $_.Outcome -eq "Success" })).Count
$FailedCount = @($Classified.Where({ $_.Outcome -eq "Failed" })).Count
$UnknownCount = @($Classified.Where({ $_.Outcome -eq "Unknown" })).Count

function Get-Pct { param($Count, $Total) if ($Total -gt 0) { [math]::Round(($Count / $Total) * 100, 1) } else { 0 } }

$OverallRow = [PSCustomObject][ordered]@{
    Date               = $Now.ToString("yyyy-MM-dd")
    Day                = "TOTAL"
    TotalAttempts      = $Total
    Successful         = $SuccessCount
    SuccessfulPct      = Get-Pct $SuccessCount $Total
    Failed             = $FailedCount
    FailedPct          = Get-Pct $FailedCount $Total
    Unknown            = $UnknownCount
}

# --- by-day breakdown -------------------------------------------------------------------

$ByDayRows = foreach ($Group in ($Classified | Where-Object { $_.Day } | Group-Object Day | Sort-Object Name)) {
    $DayTotal = $Group.Count
    $DaySuccess = @($Group.Group.Where({ $_.Outcome -eq "Success" })).Count
    $DayFailed = @($Group.Group.Where({ $_.Outcome -eq "Failed" })).Count
    $DayUnknown = @($Group.Group.Where({ $_.Outcome -eq "Unknown" })).Count
    [PSCustomObject][ordered]@{
        Date          = $Now.ToString("yyyy-MM-dd")
        Day           = $Group.Name
        TotalAttempts = $DayTotal
        Successful    = $DaySuccess
        SuccessfulPct = Get-Pct $DaySuccess $DayTotal
        Failed        = $DayFailed
        FailedPct     = Get-Pct $DayFailed $DayTotal
        Unknown       = $DayUnknown
    }
}

$Results = @($OverallRow) + @($ByDayRows)

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject $Results

Write-Host "$Total sign-in attempt(s) in raw log."
Write-Host "$SuccessCount successful ($(Get-Pct $SuccessCount $Total)%)."
Write-Host "$FailedCount failed ($(Get-Pct $FailedCount $Total)%)."
if ($UnknownCount -gt 0) { Write-Host "$UnknownCount unparseable/unknown (e.g. the 'no activity' placeholder row)." -ForegroundColor Yellow }
Write-Host "$($Results.Count) row(s) (1 overall + $($ByDayRows.Count) daily) written to $OutputPath"
