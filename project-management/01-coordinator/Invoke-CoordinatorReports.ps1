<#
.SYNOPSIS
    Unattended entry point for the PM coordinator report pipeline - fetches open projects
    from Autotask, runs the three coordinator reports, and emails the results. Meant to be
    called from a scheduled task; logs to output/scheduled-run-{yyyy-MM}.log (one file per
    month, cleaned up after 12 months by scripts/Remove-OldLogs.ps1) since nobody's watching
    the console. For interactive/manual runs, see .claude/commands/runprojectreports.md.

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

$ToAddresses = @("bwinklesky@servit.net","tmarsili@servit.net")
$EmailScript = Join-Path $PSScriptRoot "..\..\scripts\Send-EmailMessage.ps1"

try {
    Write-ToLog -LogFile $OutputFile -Message "=== Starting coordinator report run ==="

    & (Join-Path $PSScriptRoot "Get-CoordinatorProjectData.ps1")
    Write-ToLog -LogFile $OutputFile -Message "Fetched project data from Autotask"

    & (Join-Path $PSScriptRoot "Export-CoordinatorFlagsReport.ps1")
    & (Join-Path $PSScriptRoot "Export-CoordinatorPMReport.ps1")
    & (Join-Path $PSScriptRoot "Export-CoordinatorResourceReport.ps1")
    Write-ToLog -LogFile $OutputFile -Message "Generated all three reports"

    $Attachments = @(
        Join-Path $OutputDir "coordinator-project-flags-summary.csv"
        Join-Path $OutputDir "coordinator-project-flags-detail.csv"
        Join-Path $OutputDir "coordinator-project-pm-summary.csv"
        Join-Path $OutputDir "coordinator-project-pm-detail.csv"
        Join-Path $OutputDir "coordinator-project-resource-summary.csv"
        Join-Path $OutputDir "coordinator-project-resource-detail.csv"
    )

    & $EmailScript -To $ToAddresses -Subject "Project Management Coordinator Reports" -Attachments $Attachments
    Write-ToLog -LogFile $OutputFile -Message "Emailed reports to $($ToAddresses -join ', ')"
    Write-ToLog -LogFile $OutputFile -Message "=== Run completed successfully ==="
}
catch {
    Write-ToLog -LogFile $OutputFile -Message "ERROR: $($_.Exception.Message)" -Level ERROR
    Write-ToLog -LogFile $OutputFile -Message "=== Run failed ===" -Level ERROR

    # Best-effort failure notice - if this fails too (e.g. SMTP settings themselves are the
    # problem), don't let that mask the original error's exit code.
    try {
        & $EmailScript -To $ToAddresses -Subject "Project Management Coordinator Reports - FAILED" `
            -Body "The scheduled coordinator report run failed: $($_.Exception.Message)`n`nSee $OutputFile on the host machine for details."
    }
    catch {
        Write-ToLog -LogFile $OutputFile -Message "Also failed to send failure notification: $($_.Exception.Message)" -Level ERROR
    }

    exit 1
}
