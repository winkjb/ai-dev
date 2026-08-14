<#
.SYNOPSIS
    Unattended entry point for Katz's Entra admin-group audit - runs the collector then the
    analyst and emails the findings. Meant to be called from a scheduled task; logs to
    output/run-logs-{yyyy-MM}.log (shared with Katz's other audits, one file per month) since
    nobody's watching the console.

.EXAMPLE
    .\Invoke-AdminGroupAudit.ps1
#>

[CmdletBinding()]
param()

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# Import functions

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-M365-Common.ps1")

# System settings and variables

# TODO: swap to automation@alerts.servit.net once this is running unattended long-term.
$ToAddresses = @("bwinklesky@servit.net")
$CustomerInfo = Map-Customer -CustomerName "Katz"
$FromEmail = "Katz Virtual Administrator <noreply@alerts.servit.net>"
$OutputDir = Join-Path $PSScriptRoot "output"
$OutputFile = Join-Path $OutputDir ("run-logs-{0:yyyy-MM}.log" -f (Get-Date))

# ---------------------------------------------------------------------------
# Run tasks  
# ---------------------------------------------------------------------------

# Script settings and variables

$ErrorActionPreference = "Stop"
$SettingsPath = Join-Path $PSScriptRoot "CustomerSettings.txt"
$EmailScript = Join-Path $PSScriptRoot "..\..\..\scripts\Send-EmailMessage.ps1"
$AuditCsv = Join-Path $PSScriptRoot "..\02-analyst\output\$($CustomerInfo.Directory)\admingroup-audit.csv"

# Validate output directory

Test-Directory $OutputDir


try {

    # ---------------------------------------------------------------------------
    # Beginning tasks
    # ---------------------------------------------------------------------------

    Write-ToLog -LogFile $OutputFile -Message "=== Starting $($CustomerInfo.CustomerFolder) admin-group audit run ==="

    & (Join-Path $PSScriptRoot "..\01-collector\Collect-EntraAdminGroupMembers.ps1") -Directory $CustomerInfo.Directory -SettingsPath $SettingsPath
    Write-ToLog -LogFile $OutputFile -Message "Collected Entra role assignments/users/licenses"

    & (Join-Path $PSScriptRoot "..\02-analyst\Compare-AdminGroupAudit.ps1") -Directory $CustomerInfo.Directory -IncludeDisabledUsers
    Write-ToLog -LogFile $OutputFile -Message "Generated the admin-group audit"

    # ---------------------------------------------------------------------------
    # Send email
    # ---------------------------------------------------------------------------

    & $EmailScript -To $ToAddresses -Subject "$($CustomerInfo.CustomerFolder) - Entra Admin Group Audit" `
        -From $FromEmail -Attachments @($AuditCsv)

    # ---------------------------------------------------------------------------
    # Ending tasks
    # ---------------------------------------------------------------------------

    Write-ToLog -LogFile $OutputFile -Message "Emailed reports to $($ToAddresses -join ', ')"
    Write-ToLog -LogFile $OutputFile -Message "=== Run completed successfully ==="

}
catch {

    Write-ToLog -LogFile $OutputFile -Message "ERROR: $($_.Exception.Message)" -Level ERROR
    Write-ToLog -LogFile $OutputFile -Message "=== Run failed ===" -Level ERROR

    # Best-effort failure notice - if this fails too (e.g. SMTP settings themselves are the
    # problem), don't let that mask the original error's exit code.
    try {
        & $EmailScript -To $ToAddresses -Subject "$($CustomerInfo.CustomerFolder) - Entra Admin Group Audit - FAILED" `
            -From $FromEmail `
            -Body "The scheduled admin-group audit run failed: $($_.Exception.Message)`n`nSee $OutputFile on the host machine for details."
    }
    catch {
        Write-ToLog -LogFile $OutputFile -Message "Also failed to send failure notification: $($_.Exception.Message)" -Level ERROR
    }

    exit 1

}
