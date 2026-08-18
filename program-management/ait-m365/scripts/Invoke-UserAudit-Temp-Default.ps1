<#
.SYNOPSIS

.EXAMPLE
    .\Invoke-UserAudit-Temp-Default.ps1
#>

[CmdletBinding()]
param(

    [string]$CustomerDir,
    [string]$SpFolder,
    [string]$FromAddress,
    [string[]]$ToAddresses,
    [switch]$EnabledUsersOnly

)

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# System settings and variables

$OutputDir = Join-Path $PSScriptRoot "..\$($CustomerDir)\output"
$OutputFile = Join-Path $OutputDir ("run-logs-{0:yyyy-MM}.log" -f (Get-Date))

# Import functions

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-M365-Common.ps1")

# ---------------------------------------------------------------------------
# Run tasks
# ---------------------------------------------------------------------------

# Script settings and variables

$ErrorActionPreference = "Stop"
$SettingsPath = Join-Path $PSScriptRoot "..\data\reference\$($CustomerDir)\M365Settings.txt"
$EmailScript = Join-Path $PSScriptRoot "..\..\..\scripts\Send-EmailMessage.ps1"
$AuditCsv = Join-Path $PSScriptRoot "..\02-analyst\output\$($CustomerDir)\UserAudit-Temp.csv"

# Validate output directory

Test-Directory $OutputDir

try {

    # ---------------------------------------------------------------------------
    # Beginning tasks
    # ---------------------------------------------------------------------------

    Write-ToLog -LogFile $OutputFile -Message "=== Starting $($SpFolder) temp user audit run ==="

    & (Join-Path $PSScriptRoot "..\01-collector\Collect-EntraUsers.ps1") -Directory $CustomerDir -SettingsPath $SettingsPath
    Write-ToLog -LogFile $OutputFile -Message "Collected Entra users"

    & (Join-Path $PSScriptRoot "..\01-collector\Collect-EntraLicenses.ps1") -Directory $CustomerDir -SettingsPath $SettingsPath
    Write-ToLog -LogFile $OutputFile -Message "Collected Entra license catalog/assignments"

    $AnalystArgs = @{ Directory = $CustomerDir }
    if ($EnabledUsersOnly) { $AnalystArgs.EnabledUsersOnly = $true }

    & (Join-Path $PSScriptRoot "..\02-analyst\Compare-Users-Temp.ps1") @AnalystArgs
    Write-ToLog -LogFile $OutputFile -Message "Generated the temp user audit"

    # ---------------------------------------------------------------------------
    # Send email
    # ---------------------------------------------------------------------------

    & $EmailScript -To $ToAddresses -Subject "$($SpFolder) - Entra User Audit - Temp Users" `
        -From $FromAddress -Attachments @($AuditCsv)

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
        & $EmailScript -To $ToAddresses -Subject "$($SpFolder) - Entra User Audit - Temp Users - FAILED" `
            -From $FromAddress `
            -Body "The scheduled temp user audit run failed: $($_.Exception.Message)`n`nSee $OutputFile on the host machine for details."
    }
    catch {
        Write-ToLog -LogFile $OutputFile -Message "Also failed to send failure notification: $($_.Exception.Message)" -Level ERROR
    }

    exit 1

}
