<#
.SYNOPSIS
    Unattended entry point for the security coordinator report - runs the escalations
    report and emails the results. Meant to be called from a scheduled task (not yet
    registered); logs to output/scheduled-run-{yyyy-MM}.log (one file per month, cleaned up
    after 12 months by scripts/Remove-OldLogs.ps1) since nobody's watching the console.
    For interactive/manual runs, see .claude/commands/runsecurityreports.md.

.EXAMPLE
    .\Invoke-CoordinatorReports.ps1
#>

[CmdletBinding()]
param()

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# System settings and variables

$ErrorActionPreference = "Stop"
$OutputDir = Join-Path $PSScriptRoot "output"
$LogFile = Join-Path $OutputDir ("run-logs-{0:yyyy-MM}.log" -f (Get-Date))
$ToAddresses = @("bwinklesky@servit.net")

# Derived settings and variables

# Import functions

. (Join-Path $PSScriptRoot "..\..\scripts\Functions-VA-Common.ps1")
$EmailScript = Join-Path $PSScriptRoot "..\..\scripts\Send-EmailMessage.ps1"

# Validate logfile directory

Test-Directory $OutputDir

# ---------------------------------------------------------------------------
# Run scripts and log results
# ---------------------------------------------------------------------------

try {
    Write-Log "=== Starting coordinator report run ==="

    & (Join-Path $PSScriptRoot "Export-CoordinatorEscalationsReport.ps1")
    Write-Log "Generated the escalations report"

    $Attachments = @(
        Join-Path $OutputDir "coordinator-escalations-detail.csv"
        Join-Path $OutputDir "coordinator-escalations-summary.csv"
    )

    & $EmailScript -To $ToAddresses -Subject "Security Coordinator Report" -Attachments $Attachments
    Write-Log "Emailed reports to $($ToAddresses -join ', ')"
    Write-Log "=== Run completed successfully ==="
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Log "=== Run failed ==="

    # Best-effort failure notice - if this fails too (e.g. SMTP settings themselves are the
    # problem), don't let that mask the original error's exit code.
    try {
        & $EmailScript -To $ToAddresses -Subject "Security Coordinator Report - FAILED" `
            -Body "The scheduled coordinator report run failed: $($_.Exception.Message)`n`nSee $LogPath on the host machine for details."
    }
    catch {
        Write-Log "Also failed to send failure notification: $($_.Exception.Message)"
    }

    exit 1
}
