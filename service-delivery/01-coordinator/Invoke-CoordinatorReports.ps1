<#
.SYNOPSIS
    Unattended entry point for the service-delivery coordinator report - runs the ticket
    flags report and emails the results. Meant to be called from a scheduled task (not yet
    registered - scheduling is planned for later); logs to output/scheduled-run-{yyyy-MM}.log
    (one file per month, cleaned up after 12 months by scripts/Remove-OldLogs.ps1) since
    nobody's watching the console. For interactive/manual runs, see
    .claude/commands/runticketreports.md.

.EXAMPLE
    .\Invoke-CoordinatorReports.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$OutputDir = Join-Path $PSScriptRoot "output"
$OutputFile = Join-Path $OutputDir ("run-logs-{0:yyyy-MM}.log" -f (Get-Date))

. (Join-Path $PSScriptRoot "..\..\scripts\Functions-VA-Common.ps1")

Test-Directory $OutputDir

$ToAddresses = @("bwinklesky@servit.net","rpardue@servit.net","abradford@servit.net")
$EmailScript = Join-Path $PSScriptRoot "..\..\scripts\Send-EmailMessage.ps1"

try {
    Write-ToLog -LogFile $OutputFile -Message "=== Starting coordinator report run ==="

    & (Join-Path $PSScriptRoot "Get-CoordinatorTicketData.ps1")
    Write-ToLog -LogFile $OutputFile -Message "Fetched ticket data from Autotask"

    & (Join-Path $PSScriptRoot "Export-CoordinatorTicketFlagsReport.ps1")
    Write-ToLog -LogFile $OutputFile -Message "Generated the ticket flags report"

    $Attachments = @(
        Join-Path $OutputDir "coordinator-ticket-flags-summary.csv"
        Join-Path $OutputDir "coordinator-ticket-flags-detail.csv"
    )

    & $EmailScript -To $ToAddresses -Subject "Service Delivery Coordinator Reports" -Attachments $Attachments
    Write-ToLog -LogFile $OutputFile -Message "Emailed reports to $($ToAddresses -join ', ')"
    Write-ToLog -LogFile $OutputFile -Message "=== Run completed successfully ==="
}
catch {
    Write-ToLog -LogFile $OutputFile -Message "ERROR: $($_.Exception.Message)" -Level ERROR
    Write-ToLog -LogFile $OutputFile -Message "=== Run failed ===" -Level ERROR

    # Best-effort failure notice - if this fails too (e.g. SMTP settings themselves are the
    # problem), don't let that mask the original error's exit code.
    try {
        & $EmailScript -To $ToAddresses -Subject "Service Delivery Coordinator Reports - FAILED" `
            -Body "The scheduled coordinator report run failed: $($_.Exception.Message)`n`nSee $OutputFile on the host machine for details."
    }
    catch {
        Write-ToLog -LogFile $OutputFile -Message "Also failed to send failure notification: $($_.Exception.Message)" -Level ERROR
    }

    exit 1
}
