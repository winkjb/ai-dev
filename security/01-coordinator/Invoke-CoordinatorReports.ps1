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

$ErrorActionPreference = "Stop"

$OutputDir = Join-Path $PSScriptRoot "output"
if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$LogPath = Join-Path $OutputDir ("scheduled-run-{0:yyyy-MM}.log" -f (Get-Date))

function Write-Log {
    param([string]$Message)
    $Line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Write-Host $Line
    Add-Content -LiteralPath $LogPath -Value $Line
}

$ToAddresses = @("bwinklesky@servit.net")
$EmailScript = Join-Path $PSScriptRoot "..\..\scripts\Send-ReportEmail.ps1"

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
