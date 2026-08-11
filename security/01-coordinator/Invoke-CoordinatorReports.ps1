<#
.SYNOPSIS
    Unattended entry point for the security coordinator report - runs the Huntress
    escalations/incidents reports and the RocketCyber/SentinelOne threat exports, then
    emails all the results together. Meant to be called from a scheduled task (not yet
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

$ToAddresses = @("bwinklesky@servit.net","ghuelsmann@servit.net","kterza@servit.net")
$OutputDir = Join-Path $PSScriptRoot "output"
$OutputFile = Join-Path $OutputDir ("run-logs-{0:yyyy-MM}.log" -f (Get-Date))

# Import functions

. (Join-Path $PSScriptRoot "..\..\scripts\Functions-VA-Common.ps1")
$EmailScript = Join-Path $PSScriptRoot "..\..\scripts\Send-EmailMessage.ps1"

# ---------------------------------------------------------------------------
# Run specified tasks and log results
# ---------------------------------------------------------------------------

# Script settings and variables

$ErrorActionPreference = "Stop"

# Validate output directory

Test-Directory $OutputDir

# Run tasks

try {
    Write-ToLog -LogFile $OutputFile -Message "=== Starting coordinator report run ==="

    & (Join-Path $PSScriptRoot "Export-HuntressEscalations.ps1")
    Write-ToLog -LogFile $OutputFile -Message "Generated the Huntress escalations report"

    & (Join-Path $PSScriptRoot "Export-HuntressIncidents.ps1")
    Write-ToLog -LogFile $OutputFile -Message "Generated the Huntress incidents report"

    & (Join-Path $PSScriptRoot "Export-RocketCyberThreats.ps1")
    Write-ToLog -LogFile $OutputFile -Message "Generated the RocketCyber threats report"

    & (Join-Path $PSScriptRoot "Export-SentinelOneThreats.ps1")
    Write-ToLog -LogFile $OutputFile -Message "Generated the SentinelOne threats report"

    $Attachments = @(
        Join-Path $OutputDir "huntress-escalations-summary.csv"
        Join-Path $OutputDir "huntress-escalations-detail.csv"
        Join-Path $OutputDir "huntress-incidents-summary.csv"
        Join-Path $OutputDir "huntress-incidents-detail.csv"
        Join-Path $OutputDir "rocketcyber-open-incidents.csv"
        Join-Path $OutputDir "rocketcyber-isolated-devices.csv"
        Join-Path $OutputDir "sentinelonethreats-all.csv"
    )

    & $EmailScript -To $ToAddresses -Subject "Security Coordinator Reports" -Attachments $Attachments
    Write-ToLog -LogFile $OutputFile -Message "Emailed reports to $($ToAddresses -join ', ')"
    Write-ToLog -LogFile $OutputFile -Message "=== Run completed successfully ==="
}
catch {
    Write-ToLog -LogFile $OutputFile -Message "ERROR: $($_.Exception.Message)" -Level ERROR
    Write-ToLog -LogFile $OutputFile -Message "=== Run failed ===" -Level ERROR

    # Best-effort failure notice - if this fails too (e.g. SMTP settings themselves are the
    # problem), don't let that mask the original error's exit code.
    try {
        & $EmailScript -To $ToAddresses -Subject "Security Coordinator Reports - FAILED" `
            -Body "The scheduled coordinator report run failed: $($_.Exception.Message)`n`nSee $OutputFile on the host machine for details."
    }
    catch {
        Write-ToLog -LogFile $OutputFile -Message "Also failed to send failure notification: $($_.Exception.Message)" -Level ERROR
    }

    exit 1
}