<#
.SYNOPSIS
    Unattended entry point for Katz's Entra temp-groups audit - runs the collector then the
    analyst and emails the findings. Meant to be called from a scheduled task; logs to
    output/scheduled-run-{yyyy-MM}.log (one file per month) since nobody's watching the console.

.EXAMPLE
    .\Invoke-TempGroupsAudit.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-M365-Common.ps1")

$CustomerInfo = Map-Customer -CustomerName "Katz"

$OutputDir = Join-Path $PSScriptRoot "output"
$LogFile = Join-Path $OutputDir ("run-logs-{0:yyyy-MM}.log" -f (Get-Date))
Test-Directory $OutputDir

# TODO: swap to automation@alerts.servit.net once this is running unattended long-term.
$ToAddresses = @("bwinklesky@servit.net")

$SettingsPath = Join-Path $PSScriptRoot "CustomerSettings.txt"
$EmailScript = Join-Path $PSScriptRoot "..\..\..\scripts\Send-EmailMessage.ps1"
$AuditCsv = Join-Path $PSScriptRoot "..\02-analyst\output\$($CustomerInfo.Directory)\tempgroups-audit.csv"

try {
    Write-ToLog -LogFile $LogFile -Message "=== Starting $($CustomerInfo.CustomerFolder) temp-groups audit run ==="

    & (Join-Path $PSScriptRoot "..\01-collector\Collect-EntraGroups.ps1") -Directory $CustomerInfo.Directory -SettingsPath $SettingsPath
    Write-ToLog -LogFile $LogFile -Message "Collected Entra groups"

    & (Join-Path $PSScriptRoot "..\02-analyst\Compare-TempGroupsAudit.ps1") -Directory $CustomerInfo.Directory
    Write-ToLog -LogFile $LogFile -Message "Generated the temp-groups audit"

    & $EmailScript -To $ToAddresses -Subject "$($CustomerInfo.CustomerFolder) - Entra Temp Groups Audit" `
        -From "Katz Virtual Administrator <noreply@alerts.servit.net>" -Attachments @($AuditCsv)
    Write-ToLog -LogFile $LogFile -Message "Emailed reports to $($ToAddresses -join ', ')"
    Write-ToLog -LogFile $LogFile -Message "=== Run completed successfully ==="
}
catch {
    Write-ToLog -LogFile $LogFile -Message "ERROR: $($_.Exception.Message)" -Level ERROR
    Write-ToLog -LogFile $LogFile -Message "=== Run failed ===" -Level ERROR

    # Best-effort failure notice - if this fails too (e.g. SMTP settings themselves are the
    # problem), don't let that mask the original error's exit code.
    try {
        & $EmailScript -To $ToAddresses -Subject "$($CustomerInfo.CustomerFolder) - Entra Temp Groups Audit - FAILED" `
            -From "Katz Virtual Administrator <noreply@alerts.servit.net>" `
            -Body "The scheduled temp-groups audit run failed: $($_.Exception.Message)`n`nSee $LogFile on the host machine for details."
    }
    catch {
        Write-ToLog -LogFile $LogFile -Message "Also failed to send failure notification: $($_.Exception.Message)" -Level ERROR
    }

    exit 1
}
