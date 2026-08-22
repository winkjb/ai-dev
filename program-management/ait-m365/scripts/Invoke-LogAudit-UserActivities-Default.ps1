<#
.SYNOPSIS
    Collector-only orchestrator (no Analyst step - see
    ../01-collector/Collect-EntraUserActivities.ps1's .DESCRIPTION for why). Attaches the raw
    log export if it's under 30MB; otherwise leaves it on the host machine and says so in the
    email instead of attaching, matching the original script's real behavior - the file is
    always written locally either way, so an oversized export is still retrievable, just not
    by email.

.EXAMPLE
    .\Invoke-LogAudit-UserActivities-Default.ps1
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
$MaxSizeMB = 30

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
$AuditCsv = Join-Path $PSScriptRoot "..\data\raw\$($CustomerDir)\EntraUserActivities.csv"

# Validate output directory

Test-Directory $OutputDir

try {

    # ---------------------------------------------------------------------------
    # Beginning tasks
    # ---------------------------------------------------------------------------

    Write-ToLog -LogFile $OutputFile -Message "=== Starting $($SpFolder) user activity log audit run ==="

    & (Join-Path $PSScriptRoot "..\01-collector\Collect-EntraUserActivities.ps1") -Directory $CustomerDir -SettingsPath $SettingsPath
    Write-ToLog -LogFile $OutputFile -Message "Collected Entra user activity log"


    $FileSizeMB = if (Test-Path -LiteralPath $AuditCsv) { (Get-Item $AuditCsv).Length / 1MB } else { 0 }
    $TooBig = $FileSizeMB -gt $MaxSizeMB

    if ($TooBig) {
        Write-ToLog -LogFile $OutputFile -Message "Log file is $([math]::Round($FileSizeMB, 1)) MB - over the ${MaxSizeMB}MB attach limit, not attaching" -Level WARN
    }

    if ($SkipEmail) {
        Write-Output ([PSCustomObject]@{
            CsvPath  = $AuditCsv
            TooLarge = $TooBig
            SizeMB   = [math]::Round($FileSizeMB, 1)
        })
        return
    }
    # ---------------------------------------------------------------------------
    # Send email - attach if small enough, otherwise say where to find it
    # ---------------------------------------------------------------------------

    if ($TooBig) {
        $Attachments = @()
        $Body = "The user activity log for $($SpFolder) is $([math]::Round($FileSizeMB, 1)) MB - too large to email. " +
                "It's saved locally at $AuditCsv on the host machine; retrieve it directly rather than by email."
    } else {
        $Attachments = @($AuditCsv)
        $Body = "See attached report output."
    }

    & $EmailScript -To $ToAddresses -Subject "$($SpFolder) - Entra User Activity Audit" `
        -From $FromAddress -Attachments $Attachments -Body $Body

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
        & $EmailScript -To $ToAddresses -Subject "$($SpFolder) - Entra User Activity Audit - FAILED" `
            -From $FromAddress `
            -Body "The scheduled user activity log audit run failed: $($_.Exception.Message)`n`nSee $OutputFile on the host machine for details."
    }
    catch {
        Write-ToLog -LogFile $OutputFile -Message "Also failed to send failure notification: $($_.Exception.Message)" -Level ERROR
    }

    exit 1

}
