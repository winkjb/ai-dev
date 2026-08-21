<#
.SYNOPSIS
    Task Scheduler entry point for the midnight run - the long-running Monthly-End items
    (currently the ait-m365 log audits) on their own trigger, separate from the main 7:00 AM
    run, so they don't delay same-day quick-hitters and so month-boundary log data is pulled
    right after the month actually ends. See Invoke-ScheduledScripts.ps1's -FrequencyFilter
    param for how the two invocations stay mutually exclusive (same manifest, same state file,
    zero risk of double-running an entry).

.NOTES
    Register this as its own Task Scheduler trigger (e.g. daily at 00:05) - separate from the
    existing "Virtual Administrator Tasks - Daily" trigger that runs Invoke-ScheduledScripts.ps1
    directly with no arguments.

.EXAMPLE
    .\Invoke-ScheduledScripts-MonthlyEnd.ps1
#>

[CmdletBinding()]
param()

& (Join-Path $PSScriptRoot "Invoke-ScheduledScripts.ps1") -FrequencyFilter "Monthly-End" -ExpectedHour 0

if ($LASTEXITCODE) { exit $LASTEXITCODE }
