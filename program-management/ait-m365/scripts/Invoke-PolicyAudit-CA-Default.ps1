<#
.SYNOPSIS

.EXAMPLE
    .\Invoke-PolicyAudit-CA-Default.ps1
#>

[CmdletBinding()]
param(

    [string]$CustomerDir,
    [string]$SpFolder,
    [string]$FromAddress,
    [string[]]$ToAddresses

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
$AuditCsv = Join-Path $PSScriptRoot "..\02-analyst\output\$($CustomerDir)\PolicyAudit-CA.csv"

# Validate output directory

Test-Directory $OutputDir

try {

    # ---------------------------------------------------------------------------
    # Beginning tasks
    # ---------------------------------------------------------------------------

    Write-ToLog -LogFile $OutputFile -Message "=== Starting $($SpFolder) conditional access policy audit run ==="

    & (Join-Path $PSScriptRoot "..\01-collector\Collect-EntraPolicies-CA.ps1") -Directory $CustomerDir -SettingsPath $SettingsPath
    Write-ToLog -LogFile $OutputFile -Message "Collected Entra Conditional Access policies"

    & (Join-Path $PSScriptRoot "..\02-analyst\Compare-Policies-CA.ps1") -Directory $CustomerDir
    Write-ToLog -LogFile $OutputFile -Message "Generated the conditional access policy audit"

    # ---------------------------------------------------------------------------
    # Send email
    # ---------------------------------------------------------------------------

    & $EmailScript -To $ToAddresses -Subject "$($SpFolder) - Entra Conditional Access Policy Audit" `
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
        & $EmailScript -To $ToAddresses -Subject "$($SpFolder) - Entra Conditional Access Policy Audit - FAILED" `
            -From $FromAddress `
            -Body "The scheduled conditional access policy audit run failed: $($_.Exception.Message)`n`nSee $OutputFile on the host machine for details."
    }
    catch {
        Write-ToLog -LogFile $OutputFile -Message "Also failed to send failure notification: $($_.Exception.Message)" -Level ERROR
    }

    exit 1

}
