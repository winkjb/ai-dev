<#
.SYNOPSIS

.EXAMPLE
    .\Invoke-SiteAuditSharepoint-Disable-Default.ps1
#>

[CmdletBinding()]
param(

    [string]$CustomerDir,
    [string]$SpFolder,
    [string]$FromAddress,
    [string[]]$ToAddresses,
    [switch]$SkipEmail

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
$AuditCsv = Join-Path $PSScriptRoot "..\02-analyst\output\$($CustomerDir)\Sharepoint-Disable.csv"

# Validate output directory

Test-Directory $OutputDir

try {

    # ---------------------------------------------------------------------------
    # Beginning tasks
    # ---------------------------------------------------------------------------

    Write-ToLog -LogFile $OutputFile -Message "=== Starting $($SpFolder) SharePoint disable audit run ==="

    & (Join-Path $PSScriptRoot "..\01-collector\Collect-EntraSharepointActivity.ps1") -Directory $CustomerDir -SettingsPath $SettingsPath
    Write-ToLog -LogFile $OutputFile -Message "Collected SharePoint activity report"

    & (Join-Path $PSScriptRoot "..\02-analyst\Compare-Sharepoint-Disable.ps1") -Directory $CustomerDir
    Write-ToLog -LogFile $OutputFile -Message "Generated the SharePoint disable audit"


    if ($SkipEmail) {
        Write-Output $AuditCsv
        return
    }
    # ---------------------------------------------------------------------------
    # Send email
    # ---------------------------------------------------------------------------

    & $EmailScript -To $ToAddresses -Subject "$($SpFolder) - SharePoint Site Audit - Inactive" `
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
        & $EmailScript -To $ToAddresses -Subject "$($SpFolder) - SharePoint Site Audit - Inactive - FAILED" `
            -From $FromAddress `
            -Body "The scheduled SharePoint disable audit run failed: $($_.Exception.Message)`n`nSee $OutputFile on the host machine for details."
    }
    catch {
        Write-ToLog -LogFile $OutputFile -Message "Also failed to send failure notification: $($_.Exception.Message)" -Level ERROR
    }

    exit 1

}
