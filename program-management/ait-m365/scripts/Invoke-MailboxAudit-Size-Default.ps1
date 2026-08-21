<#
.SYNOPSIS

.EXAMPLE
    .\Invoke-MailboxAudit-Size-Default.ps1
#>

[CmdletBinding()]
param(

    [string]$CustomerDir,
    [string]$SpFolder,
    [string]$FromAddress,
    [string[]]$ToAddresses,
    [switch]$SkipEmail,

    # No default here - left unbound if the caller omits it, so
    # ..\02-analyst\Compare-Mailboxes-Size.ps1's own default (75) is the single source of
    # truth for the baseline threshold rather than duplicating that number in two places where
    # it could silently drift out of sync.
    [double]$MinStoragePercentage

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
$AuditCsv = Join-Path $PSScriptRoot "..\02-analyst\output\$($CustomerDir)\MailboxAudit-Size.csv"

# Validate output directory

Test-Directory $OutputDir

try {

    # ---------------------------------------------------------------------------
    # Beginning tasks
    # ---------------------------------------------------------------------------

    Write-ToLog -LogFile $OutputFile -Message "=== Starting $($SpFolder) mailbox size audit run ==="

    & (Join-Path $PSScriptRoot "..\01-collector\Collect-EntraLicenses.ps1") -Directory $CustomerDir -SettingsPath $SettingsPath
    Write-ToLog -LogFile $OutputFile -Message "Collected Entra license catalog/assignments"

    & (Join-Path $PSScriptRoot "..\01-collector\Collect-EntraMailboxUsage.ps1") -Directory $CustomerDir -SettingsPath $SettingsPath
    Write-ToLog -LogFile $OutputFile -Message "Collected Entra mailbox usage report"

    $AnalystArgs = @{ Directory = $CustomerDir }
    if ($PSBoundParameters.ContainsKey('MinStoragePercentage')) { $AnalystArgs.MinStoragePercentage = $MinStoragePercentage }

    & (Join-Path $PSScriptRoot "..\02-analyst\Compare-Mailboxes-Size.ps1") @AnalystArgs
    Write-ToLog -LogFile $OutputFile -Message "Generated the mailbox size audit"


    if ($SkipEmail) {
        Write-Output $AuditCsv
        return
    }
    # ---------------------------------------------------------------------------
    # Send email
    # ---------------------------------------------------------------------------

    $Subject = if ($PSBoundParameters.ContainsKey('MinStoragePercentage')) {
        "$($SpFolder) - Entra Mailbox Size Audit - over $($MinStoragePercentage)% usage"
    } else {
        "$($SpFolder) - Entra Mailbox Size Audit"
    }

    & $EmailScript -To $ToAddresses -Subject $Subject `
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
        & $EmailScript -To $ToAddresses -Subject "$($SpFolder) - Entra Mailbox Size Audit - FAILED" `
            -From $FromAddress `
            -Body "The scheduled mailbox size audit run failed: $($_.Exception.Message)`n`nSee $OutputFile on the host machine for details."
    }
    catch {
        Write-ToLog -LogFile $OutputFile -Message "Also failed to send failure notification: $($_.Exception.Message)" -Level ERROR
    }

    exit 1

}
