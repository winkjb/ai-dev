<#
.SYNOPSIS

.EXAMPLE
    .\Invoke-MailboxAudit-LicensedShared-Default.ps1
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
$AuditCsv = Join-Path $PSScriptRoot "..\02-analyst\output\$($CustomerDir)\MailboxAudit-LicensedAndShared.csv"

# Validate output directory

Test-Directory $OutputDir

try {

    # ---------------------------------------------------------------------------
    # Beginning tasks
    # ---------------------------------------------------------------------------

    Write-ToLog -LogFile $OutputFile -Message "=== Starting $($SpFolder) licensed shared mailbox audit run ==="

    & (Join-Path $PSScriptRoot "..\01-collector\Collect-EntraUsers.ps1") -Directory $CustomerDir -SettingsPath $SettingsPath
    Write-ToLog -LogFile $OutputFile -Message "Collected Entra users"

    & (Join-Path $PSScriptRoot "..\01-collector\Collect-EntraLicenses.ps1") -Directory $CustomerDir -SettingsPath $SettingsPath
    Write-ToLog -LogFile $OutputFile -Message "Collected Entra license catalog/assignments"

    # Two-pass: ask the Analyst which UPNs it actually needs mailbox purpose for (a pure
    # CSV-only pass, no Graph calls) before paying for the expensive per-user purpose lookup -
    # on a large tenant, checking everyone instead of just the licensed candidates was measured
    # costing minutes instead of seconds. See Compare-Mailboxes-LicensedShared.ps1's -ListCandidateUpns.
    $CandidateUpns = & (Join-Path $PSScriptRoot "..\02-analyst\Compare-Mailboxes-LicensedShared.ps1") -Directory $CustomerDir -ListCandidateUpns
    Write-ToLog -LogFile $OutputFile -Message "Identified $(@($CandidateUpns).Count) licensed candidate(s)"

    $ScopedPurposePath = Join-Path $PSScriptRoot "..\data\raw\$($CustomerDir)\EntraMailboxPurpose-LicensedShared.csv"
    & (Join-Path $PSScriptRoot "..\01-collector\Collect-EntraMailboxPurpose.ps1") -Directory $CustomerDir -SettingsPath $SettingsPath -Upns @($CandidateUpns) -OutputPath $ScopedPurposePath
    Write-ToLog -LogFile $OutputFile -Message "Collected Entra mailbox purpose (scoped to candidates)"

    & (Join-Path $PSScriptRoot "..\01-collector\Collect-EntraMailboxUsage.ps1") -Directory $CustomerDir -SettingsPath $SettingsPath
    Write-ToLog -LogFile $OutputFile -Message "Collected Entra mailbox usage report"

    & (Join-Path $PSScriptRoot "..\02-analyst\Compare-Mailboxes-LicensedShared.ps1") -Directory $CustomerDir
    Write-ToLog -LogFile $OutputFile -Message "Generated the licensed shared mailbox audit"


    if ($SkipEmail) {
        Write-Output $AuditCsv
        return
    }
    # ---------------------------------------------------------------------------
    # Send email
    # ---------------------------------------------------------------------------

    & $EmailScript -To $ToAddresses -Subject "$($SpFolder) - Entra User Audit - Licensed Shared Mailboxes" `
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
        & $EmailScript -To $ToAddresses -Subject "$($SpFolder) - Entra User Audit - Licensed Shared Mailboxes - FAILED" `
            -From $FromAddress `
            -Body "The scheduled licensed shared mailbox audit run failed: $($_.Exception.Message)`n`nSee $OutputFile on the host machine for details."
    }
    catch {
        Write-ToLog -LogFile $OutputFile -Message "Also failed to send failure notification: $($_.Exception.Message)" -Level ERROR
    }

    exit 1

}
