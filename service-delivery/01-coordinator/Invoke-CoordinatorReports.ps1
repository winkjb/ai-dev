<#
.SYNOPSIS
    Unattended entry point for the service-delivery coordinator report - runs the ticket
    flags report and emails the results. Meant to be called from a scheduled task (not yet
    registered - scheduling is planned for later); logs to output/scheduled-run.log since
    nobody's watching the console. For interactive/manual runs, see
    .claude/commands/runticketreports.md.

.EXAMPLE
    .\Invoke-CoordinatorReports.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$OutputDir = Join-Path $PSScriptRoot "output"
if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$LogPath = Join-Path $OutputDir "scheduled-run.log"

function Write-Log {
    param([string]$Message)
    $Line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Write-Host $Line
    Add-Content -LiteralPath $LogPath -Value $Line
}

$ToAddresses = @("bwinklesky@servit.net", "rpardue@servit.net")
$EmailScript = Join-Path $PSScriptRoot "..\..\scripts\Send-ReportEmail.ps1"

try {
    Write-Log "=== Starting coordinator report run ==="

    & (Join-Path $PSScriptRoot "Get-CoordinatorTicketData.ps1")
    Write-Log "Fetched ticket data from Autotask"

    & (Join-Path $PSScriptRoot "Export-CoordinatorTicketFlagsReport.ps1")
    Write-Log "Generated the ticket flags report"

    $Attachments = @(
        Join-Path $OutputDir "coordinator-ticket-flags-detail.csv"
        Join-Path $OutputDir "coordinator-ticket-flags-summary.csv"
    )

    & $EmailScript -To $ToAddresses -Subject "Service Delivery Coordinator Reports" -Attachments $Attachments
    Write-Log "Emailed reports to $($ToAddresses -join ', ')"
    Write-Log "=== Run completed successfully ==="
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Log "=== Run failed ==="

    # Best-effort failure notice - if this fails too (e.g. SMTP settings themselves are the
    # problem), don't let that mask the original error's exit code.
    try {
        & $EmailScript -To $ToAddresses -Subject "Service Delivery Coordinator Reports - FAILED" `
            -Body "The scheduled coordinator report run failed: $($_.Exception.Message)`n`nSee $LogPath on the host machine for details."
    }
    catch {
        Write-Log "Also failed to send failure notification: $($_.Exception.Message)"
    }

    exit 1
}
